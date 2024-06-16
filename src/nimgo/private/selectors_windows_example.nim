proc readBuffer*(f: AsyncFile, buf: pointer, size: int): Future[int] =
  ## Read `size` bytes from the specified file asynchronously starting at
  ## the current position of the file pointer.
  ##
  ## If the file pointer is past the end of the file then zero is returned
  ## and no bytes are read into `buf`
  var retFuture = newFuture[int]("asyncfile.readBuffer")

  when defined(windows) or defined(nimdoc):
    var ol = newCustom()
    ol.data = CompletionData(fd: f.fd, cb:
      proc (fd: AsyncFD, bytesCount: DWORD, errcode: OSErrorCode) =
        if not retFuture.finished:
          if errcode == OSErrorCode(-1):
            assert bytesCount > 0
            assert bytesCount <= size
            f.offset.inc bytesCount
            retFuture.complete(bytesCount)
          else:
            if errcode.int32 == ERROR_HANDLE_EOF:
              retFuture.complete(0)
            else:
              retFuture.fail(newOSError(errcode))
    )
    ol.offset = DWORD(f.offset and 0xffffffff)
    ol.offsetHigh = DWORD(f.offset shr 32)

    # According to MSDN we're supposed to pass nil to lpNumberOfBytesRead.
    let ret = readFile(f.fd.Handle, buf, size.int32, nil,
                       cast[POVERLAPPED](ol))
    if not ret.bool:
      let err = osLastError()
      if err.int32 != ERROR_IO_PENDING:
        GC_unref(ol)
        if err.int32 == ERROR_HANDLE_EOF:
          # This happens in Windows Server 2003
          retFuture.complete(0)
        else:
          retFuture.fail(newOSError(err))
    else:
      # Request completed immediately.
      var bytesRead: DWORD
      let overlappedRes = getOverlappedResult(f.fd.Handle,
          cast[POVERLAPPED](ol), bytesRead, false.WINBOOL)
      if not overlappedRes.bool:
        let err = osLastError()
        if err.int32 == ERROR_HANDLE_EOF:
          retFuture.complete(0)
        else:
          retFuture.fail(newOSError(osLastError()))
      else:
        assert bytesRead > 0
        assert bytesRead <= size
        f.offset.inc bytesRead
        retFuture.complete(bytesRead)