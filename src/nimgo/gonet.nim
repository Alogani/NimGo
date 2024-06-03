{.warning: "gonet is completly untested. Please remove this line, use at your own risk and tell me if it works".}

import ./eventdispatcher
import ./private/[buffer, timeoutwatcher]
import std/[nativesockets, net, options, oserrors]

export net


type
    GoSocket* = ref object
        pollFd: PollFd
        socket: Socket
        readBuffer: Buffer
        writeBuffer: Buffer
        closed: bool


proc newGoSocket*(domain: Domain = AF_INET; sockType: SockType = SOCK_STREAM;
                    protocol: Protocol = IPPROTO_TCP; buffered = true;
                    inheritable = defined(nimInheritHandles)): GoSocket =
    let socket = newSocket(domain, sockType, protocol, false, inheritable)
    GoSocket(
        socket: socket,
        pollFd: registerHandle(socket.getFd(), {Event.Read, Event.Write}),
        readBuffer: if buffered: newBuffer() else: nil,
        writeBuffer: if buffered: newBuffer() else: nil,
    )


when defined(ssl):
    proc sslHandle*(gosocket: GoSocke): SslPtr =
        gosocket.socket.sslHandle

    proc wrapSocket*(ctx: SslContext, gosocket: GoSocket) =
        wrapSocket(ctx, gosocket.socket)


    proc wrapConnectedSocket*(ctx: SslContext, gosocket: GoSocke,
                            handshake: SslHandshakeType,
                            hostname: string = "") =
        wrapConnectedSocket(ctx, gosocket.socket, handshake, hostname)

    proc getPeerCertificates*(gosocket: GoSocket): seq[Certificate] =
        gosocket.socket.getPeerCertificates()

proc accept*(gosocket: GoSocket, flags = {SafeDisconn};
            inheritable = defined(nimInheritHandles), timeoutMs = -1): Option[GoSocket] =
    if not suspendUntilRead(gosocket.pollFd, timeoutMs):
        return none(GoSocket)
    var client: Socket
    accept(gosocket.socket, client, flags, inheritable)
    return some GoSocket(
        socket: client,
        pollFd: registerHandle(client.getFd(), {Event.Read, Event.Write}),
        readBuffer: if gosocket.readBuffer != nil: newBuffer() else: nil,
        writeBuffer: if gosocket.writeBuffer != nil: newBuffer() else: nil,
    )

proc acceptAddr*(gosocket: GoSocket; flags = {SafeDisconn};
                    inheritable = defined(nimInheritHandles), timeoutMs = -1): Option[tuple[address: string, client: GoSocket]] =
    if not suspendUntilRead(gosocket.pollFd, timeoutMs):
        return none(tuple[address: string, client: GoSocket])
    var client: Socket
    var address = ""
    acceptAddr(gosocket.socket, client, address, flags, inheritable)
    return some (
        address,
        GoSocket(socket: client, pollFd: registerHandle(client.getFd(), {Event.Read, Event.Write}))
    )

proc bindAddr*(gosocket: GoSocket; port = Port(0); address = "") =
    gosocket.socket.bindAddr(port, address)

proc bindUnix*(gosocket: GoSocket; path: string) =
    gosocket.socket.bindUnix(path)

proc close*(gosocket: GoSocket) =
    gosocket.pollFd.unregister()
    gosocket.socket.close()
    gosocket.closed = true

proc connect*(gosocket: GoSocket; address: string; port: Port) =
    discard suspendUntilRead(gosocket.pollFd, -1)
    connect(gosocket.socket, address, port)

proc connectWithTimeout*(gosocket: GoSocket; address: string; port: Port, timeoutMs = -1): bool =
    if not suspendUntilRead(gosocket.pollFd, timeoutMs):
        return false
    connect(gosocket.socket, address, port)
    return true

proc connectUnix*(gosocket: GoSocket; path: string, timeoutMs = -1) =
    discard suspendUntilRead(gosocket.pollFd, timeoutMs)
    connectUnix(gosocket.socket, path)

proc connectUnixWithTimeout*(gosocket: GoSocket; path: string, timeoutMs = -1): bool =
    if not suspendUntilRead(gosocket.pollFd, timeoutMs):
        return false
    connectUnix(gosocket.socket, path)
    return true

proc dial*(address: string; port: Port; protocol = IPPROTO_TCP; buffered = true): GoSocket =
    # https://github.com/nim-lang/Nim/blob/version-2-0/lib/pure/net.nim#L1989
    let sockType = protocol.toSockType()

    let aiList = getAddrInfo(address, port, AF_UNSPEC, sockType, protocol)

    var fdPerDomain: array[low(Domain).ord..high(Domain).ord, SocketHandle]
    for i in low(fdPerDomain)..high(fdPerDomain):
        fdPerDomain[i] = osInvalidSocket
    template closeUnusedFds(domainToKeep = -1) {.dirty.} =
        for i, fd in fdPerDomain:
            if fd != osInvalidSocket and i != domainToKeep:
                fd.close()

    var success = false
    var lastError: OSErrorCode
    var it = aiList
    var domain: Domain
    var lastFd: SocketHandle
    var pollFd: PollFd
    while it != nil:
        let domainOpt = it.ai_family.toKnownDomain()
        if domainOpt.isNone:
            it = it.ai_next
            continue
        domain = domainOpt.unsafeGet()
        lastFd = fdPerDomain[ord(domain)]
        if lastFd == osInvalidSocket:
            lastFd = createNativeSocket(domain, sockType, protocol)
            if lastFd == osInvalidSocket:
                # we always raise if socket creation failed, because it means a
                # network system problem (e.g. not enough FDs), and not an unreachable
                # address.
                let err = osLastError()
                freeAddrInfo(aiList)
                closeUnusedFds()
                raiseOSError(err)
            fdPerDomain[ord(domain)] = lastFd
        pollFd = registerHandle(lastFd, {Event.Read, Event.Write})
        discard suspendUntilRead(pollFd)
        if connect(lastFd, it.ai_addr, it.ai_addrlen.SockLen) == 0'i32:
            success = true
            break
        pollFd.unregister()
        lastError = osLastError()
        it = it.ai_next
    freeAddrInfo(aiList)
    closeUnusedFds(ord(domain))

    if success:
        result = GoSocket(
            socket: newSocket(lastFd, domain, sockType, protocol, buffered),
            pollFd: pollFd)
    elif lastError != 0.OSErrorCode:
        raiseOSError(lastError)
    else:
        raise newException(IOError, "Couldn't resolve address: " & address)

proc getFd*(gosocket: GoSocket): SocketHandle =
    getFd(gosocket.socket)

proc getLocalAddr*(gosocket: GoSocket): (string, Port) =
    getLocalAddr(gosocket.socket)

proc getPeerAddr*(gosocket: GoSocket): (string, Port) =
    getPeerAddr(gosocket.socket)

proc getSelectorFileHandle*(gosocket: GoSocket): PollFd =
    gosocket.pollFd

proc getSockOpt*(gosocket: GoSocket; opt: SOBool; level = SOL_SOCKET): bool =
    getSockOpt(gosocket.socket, opt, level)

proc hasDataBuffered*(gosocket: GoSocket): bool =
    gosocket.readBuffer != nil and not (
        gosocket.readBuffer.empty() and gosocket.writeBuffer.empty())

proc isClosed*(gosocket: GoSocket): bool =
    gosocket.closed

proc isSsl*(gosocket: GoSocket): bool =
    isSsl(gosocket.socket)

proc listen*(gosocket: GoSocket; backlog = SOMAXCONN) =
    listen(gosocket.socket, backlog)

proc recvBufferImpl(s: GoSocket; data: pointer, size: int, timeoutMs: int): int =
    ## Bypass the buffer
    if not suspendUntilRead(s.pollFd, timeoutMs):
        return -1
    let bytesCount = recv(s.socket, data, size)
    return bytesCount

proc recvImpl(s: GoSocket, size: Positive, timeoutMs: int): string =
    result = newStringOfCap(size)
    result.setLen(1)
    let bytesCount = s.recvBufferImpl(addr(result[0]), size, timeoutMs)
    if bytesCount <= 0:
        return ""
    result.setLen(bytesCount)

proc recv*(s: GoSocket; size: int, timeoutMs = -1): string =
    if s.readBuffer != nil:
        if s.readBuffer.len() < size:
            let data = s.recvImpl(max(size, DefaultBufferSize), timeoutMs)
            if data != "":
                s.readBuffer.write(data)
        return s.readBuffer.read(size)
    else:
        return s.recvImpl(size, timeoutMs)

proc recvFrom*[T: string | IpAddress](s: GoSocket; data: var string;
            length: int; address: var T;
            port: var Port; flags = 0'i32, timeoutMs = -1): int =
    ## Always unbuffered, ignore if data is already in buffer
    ## Can raise exception
    if not suspendUntilRead(s.pollFd, timeoutMs):
        return -1
    return recvFrom(s.socket, data, length, address, port, flags)

proc recvLine*(s: GoSocket; keepNewLine = false,
              timeoutMs = -1): string =
    let timeout = TimeOutWatcher.init(timeoutMs)
    if s.readBuffer != nil:
        while true:
            let line = s.readBuffer.readLine(keepNewLine)
            if line.len() != 0:
                return line
            let data = s.recvImpl(DefaultBufferSize, timeout.getRemainingMs())
            if data.len() == 0:
                return s.readBuffer.readAll()
            s.readBuffer.write(data)
    else:
        const BufSizeLine = 100
        var line = newString(BufSizeLine)
        var length = 0
        while true:
            var c: char
            let readCount = s.recvBufferImpl(addr(c), 1, timeout.getRemainingMs())
            if readCount <= 0:
                line.setLen(length)
                return line
            if c == '\c':
                discard s.recvBufferImpl(addr(c), 1, timeout.getRemainingMs())
                if keepNewLine:
                    line[length] = '\n'
                    line.setLen(length + 1)
                else:
                    line.setLen(length)
                return line
            if c == '\L':
                if keepNewLine:
                    line[length] = '\n'
                    line.setLen(length + 1)
                else:
                    line.setLen(length)
                return line
            if length == line.len():
                line.setLen(line.len() * 2)
            line[length] = c
            length += 1

proc sendImpl(s: GoSocket; data: string, timeoutMs: int): int =
    ## Bypass the buffer
    if data.len() == 0:
        return 0
    if not suspendUntilWrite(s.pollFd, timeoutMs):
        return -1
    let bytesCount = send(s.socket, addr(data[0]), data.len())
    return bytesCount

proc send*(s: GoSocket; data: string, timeoutMs = -1): int =
    if s.writeBuffer != nil:
        s.writeBuffer.write(data)
        if s.writeBuffer.len() > DefaultBufferSize:
            return sendImpl(s, s.writeBuffer.readAll(), timeoutMs)
        else:
            return data.len()
    else:
        return sendImpl(s, data, timeoutMs)

proc sendTo*(s: GoSocket; address: IpAddress; port: Port; data: string,
            flags = 0'i32, timeoutMs = -1): int {.discardable.} =
    ## Always unbuffered
    ## Can raise exception
    if data.len() == 0:
        return 0
    if not suspendUntilWrite(s.pollFd, timeoutMs):
        return -1
    return sendTo(s.socket, address, port, data, flags)

proc setSockOpt*(gosocket: GoSocket; opt: SOBool; value: bool;
                level = SOL_SOCKET) =
    setSockOpt(gosocket.socket, opt, value, level)
