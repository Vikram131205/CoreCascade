; C = A x B for 2x2 matrices, one thread per element of C (4 threads)
; GPU data addresses: A at 0..3, B at 4..7, C at 8..11 (row-major)
.kernel matmul
.equ    N,     2
.equ    baseA, 0
.equ    baseB, 4
.equ    baseC, 8

        MUL   R0, %blockIdx, %blockDim
        ADD   R0, R0, %threadIdx        ; i = element of C
        CONST R1, #1
        CONST R2, #N
        CONST R3, #baseA
        CONST R4, #baseB
        CONST R5, #baseC
        DIV   R6, R0, R2                ; row = i / N
        MUL   R7, R6, R2
        SUB   R7, R0, R7                ; col = i - row * N
        CONST R8, #0                    ; acc
        CONST R9, #0                    ; k
LOOP:   MUL   R10, R6, R2
        ADD   R10, R10, R9
        ADD   R10, R10, R3
        LDR   R10, R10                  ; A[row * N + k]
        MUL   R11, R9, R2
        ADD   R11, R11, R7
        ADD   R11, R11, R4
        LDR   R11, R11                  ; B[k * N + col]
        MUL   R12, R10, R11
        ADD   R8, R8, R12               ; acc += A * B
        ADD   R9, R9, R1                ; k++
        CMP   R9, R2
        BRn   LOOP                      ; loop while k != N (BRn = "not equal" on tiny-gpu)
        ADD   R9, R5, R0
        STR   R9, R8                    ; C[i] = acc
        RET
