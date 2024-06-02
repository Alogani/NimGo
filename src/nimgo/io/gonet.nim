import ../eventdispatcher
when defined(windows):
    import std/winlean
else:
    import std/posix
import std/net
export net


type
    GoSocket* = ref object
        pollFd: PollFd
        socket: Socket
        closed: bool

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
            inheritable = defined(nimInheritHandles), timeoutMs = -1): GoSocket =
    if not suspendUntilRead(gosocket.pollFd, timeoutMs):
        return nil
    var client: Socket
    accept(gosocket.socket, client, flags, inheritable)
    return GoSocket(socket: client, pollFd: registerHandle(client.getFd(), {Event.Read, Event.Write}))

proc acceptAddr*(gosocket: GoSocket; flags = {SafeDisconn};
                    inheritable = defined(nimInheritHandles), timeoutMs = -1): tuple[address: string, client: GoSocket] =
    if not suspendUntilRead(gosocket.pollFd, timeoutMs):
        return ("", nil)
    var client: Socket
    var address = ""
    acceptAddr(gosocket.socket, client, address, flags, inheritable)
    return (
        address,
        GoSocket(socket: client, pollFd: registerHandle(client.getFd(), {Event.Read, Event.Write}))
    )

proc bindAddr*(gosocket: GoSocket; port = Port(0); address = "") =
    gosocket.socket.bindAddr(port, address)

proc bindUnix*(gosocket: GoSocket; path: string) =
    gosocket.socket.bindUnix(path)

proc close*(gosocket: GoSocket) =
    gosocket.socket.close()
    gosocket.pollFd.unregister()
    gosocket.closed = true

proc connect*(gosocket: GoSocket; address: string; port: Port, timeoutMs = -1): bool =
    if not suspendUntilRead(gosocket.pollFd, timeoutMs):
        return false
    connect(gosocket.socket, address, port)
    return true

proc connectUnix*(gosocket: GoSocket; path: string, timeoutMs = -1): bool =
    if not suspendUntilRead(gosocket.pollFd, timeoutMs):
        return false
    connectUnix(gosocket.socket, path)
    return true

proc dial*(address: string; port: Port; protocol = Protocol.IPPROTO_TCP; buffered = true): GoSocket =
    discard

proc getFd*(gosocket: GoSocket): SocketHandle =
    getFd(gosocket.socket)

proc getLocalAddr*(gosocket: GoSocket): (string, Port) =
    getLocalAddr(gosocket.socket)

proc getPeerAddr*(gosocket: GoSocket): (string, Port) =
    getPeerAddr(gosocket.socket)

proc getSockOpt*(gosocket: GoSocket; opt: SOBool; level = SOL_SOCKET): bool =
    getSockOpt(gosocket.socket, opt, level)

proc hasDataBuffered*(gosocket: GoSocket): bool =
    discard

proc isClosed*(gosocket: GoSocket): bool =
    gosocket.closed

proc isSsl*(gosocket: GoSocket): bool =
    isSsl(gosocket.socket)

proc listen*(gosocket: GoSocket; backlog = SOMAXCONN) =
    listen(gosocket.socket, backlog)

proc newGoSocket*(domain: Domain = AF_INET; sockType: SockType = SOCK_STREAM;
                    protocol: Protocol = IPPROTO_TCP; buffered = true;
                    inheritable = defined(nimInheritHandles)): GoSocket =
    ## TODO: buffered
    let socket = newSocket(domain, sockType, protocol, false, inheritable)
    GoSocket(socket: socket, pollFd: registerHandle(socket.getFd(), {Event.Read, Event.Write}))

proc recv*(gosocket: GoSocket; size: int; flags = {SafeDisconn}, timeoutMs = -1): string =
    if not suspendUntilRead(gosocket.pollFd, timeoutMs):
        return ""
    recv(gosocket.socket, size, -1, flags)

proc recvFrom*(gosocket: GoSocket; data: string; size: int;
              address: string; port: Port;
              flags = {SafeDisconn}): int =
    discard

proc recvLine*(gosocket: GoSocket; flags = {SafeDisconn};
              maxLength = MaxLineLength): string =
    discard

proc send*(gosocket: GoSocket; data: string; flags = {SafeDisconn}, timeoutMs = -1): bool =
    if not suspendUntilWrite(gosocket.pollFd, timeoutMs):
        return false
    send(gosocket.socket, data, flags)

proc sendTo*(gosocket: GoSocket; address: string; port: Port; data: string;
            flags = {SafeDisconn}): bool =
    discard

proc setSockOpt*(gosocket: GoSocket; opt: SOBool; value: bool;
                level = SOL_SOCKET) =
    setSockOpt(gosocket.socket, opt, value, level)
