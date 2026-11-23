; pixel[i] = 3 * i, written into a framebuffer slice
; launched in byte mode: GPU address i = byte i of the data window
.kernel pattern

        MUL   R0, %blockIdx, %blockDim
        ADD   R0, R0, %threadIdx        ; i
        CONST R1, #3
        MUL   R2, R0, R1                ; 3 * i
        STR   R0, R2                    ; pixel[i]
        RET
