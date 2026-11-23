; C[i] = A[i] + B[i], one thread per element (8 threads)
; GPU data addresses (word mode: GPU address a = word a of the data window)
.kernel matadd
.equ    baseA, 0
.equ    baseB, 8
.equ    baseC, 16

        MUL   R0, %blockIdx, %blockDim
        ADD   R0, R0, %threadIdx        ; i = blockIdx * blockDim + threadIdx
        CONST R1, #baseA
        CONST R2, #baseB
        CONST R3, #baseC
        ADD   R4, R1, R0
        LDR   R4, R4                    ; A[i]
        ADD   R5, R2, R0
        LDR   R5, R5                    ; B[i]
        ADD   R6, R4, R5                ; A[i] + B[i]
        ADD   R7, R3, R0
        STR   R7, R6                    ; C[i]
        RET
