option casemap:none
extern ExitProcess:proc
.code
start PROC
    sub rsp, 28h
    invoke ExitProcess, 0
start ENDP
END
