; HW1: two periodic USART messages, ATmega8, AVR Assembler.
; Clock: 16 MHz. USART: 1 Mbaud, 8N1, U2X=1, UBRR=1.
;
; The source is intentionally split into a short deterministic ISR and a
; foreground command parser. Timer1 always runs; commands never stop it.

.include "m8def.inc"

.equ F_CPU             = 16000000
.equ UBRR_1M            = 1
.equ PING_INTERVAL      = 2880
.equ PONG_INTERVAL      = 2880
.equ PONG_PHASE         = 960
.equ STRING_CAPACITY    = 24

.dseg
timer1_interval: .byte 2
timer2_interval: .byte 2
next_timer1:     .byte 2
next_timer2:     .byte 2
tx_ptr:          .byte 2
tx_left:         .byte 1
tx_busy:         .byte 1
pending1:        .byte 1
pending2:        .byte 1
diag_pending:    .byte 1
string1_len:     .byte 1
string2_len:     .byte 1
string1:         .byte STRING_CAPACITY
string2:         .byte STRING_CAPACITY
rx_len:          .byte 1
rx_buf:          .byte STRING_CAPACITY
cand_timer1:     .byte 2
cand_timer2:     .byte 2
err_string:      .byte 5

.cseg
.org 0x0000
    rjmp reset
.org OC1Aaddr
    rjmp timer1_compare_isr
.org URXCaddr
    rjmp usart_rx_isr
.org UDREaddr
    rjmp usart_udre_isr

reset:
    clr r1
    ldi r16, high(RAMEND)
    out SPH, r16
    ldi r16, low(RAMEND)
    out SPL, r16

    ; USART: double speed, 1 Mbaud, receiver/TX/RX interrupt enabled.
    ldi r16, (1<<U2X)
    out UCSRA, r16
    ldi r16, UBRR_1M
    out UBRRL, r16
    clr r16
    out UBRRH, r16
    ldi r16, (1<<RXEN)|(1<<TXEN)|(1<<RXCIE)
    out UCSRB, r16
    ldi r16, (1<<URSEL)|(1<<UCSZ1)|(1<<UCSZ0)
    out UCSRC, r16

    ; Timer1: normal mode, no prescaler, compare-A interrupt.
    clr r16
    out TCCR1A, r16
    ldi r16, (1<<CS10)
    out TCCR1B, r16
    ldi r16, (1<<OCIE1A)
    out TIMSK, r16

    rcall load_defaults
    rcall restart_timers
    sei
main_loop:
    rcall start_pending_message
    rcall process_complete_command
    rjmp main_loop

; Set default strings and intervals.  String bytes are entered explicitly to
; keep the program independent of a particular assembler's string directives.
load_defaults:
    ldi r16, low(PING_INTERVAL)
    sts timer1_interval, r16
    ldi r16, high(PING_INTERVAL)
    sts timer1_interval+1, r16
    ldi r16, low(PONG_INTERVAL)
    sts timer2_interval, r16
    ldi r16, high(PONG_INTERVAL)
    sts timer2_interval+1, r16
    ldi r16, 6
    sts string1_len, r16
    sts string2_len, r16
    ldi ZL, low(string1)
    ldi ZH, high(string1)
    ldi r16, 'p'
    st Z+, r16
    ldi r16, 'i'
    st Z+, r16
    ldi r16, 'n'
    st Z+, r16
    ldi r16, 'g'
    st Z+, r16
    ldi r16, 13
    st Z+, r16
    ldi r16, 10
    st Z+, r16
    ldi ZL, low(string2)
    ldi ZH, high(string2)
    ldi r16, 'p'
    st Z+, r16
    ldi r16, 'o'
    st Z+, r16
    ldi r16, 'n'
    st Z+, r16
    ldi r16, 'g'
    st Z+, r16
    ldi r16, 13
    st Z+, r16
    ldi r16, 10
    st Z+, r16
    ldi ZL, low(err_string)
    ldi ZH, high(err_string)
    ldi r16, 'E'
    st Z+, r16
    ldi r16, 'R'
    st Z+, r16
    st Z+, r16
    ldi r16, 13
    st Z+, r16
    ldi r16, 10
    st Z+, r16
    ret

; Atomically choose future phases. Timer clock is not stopped.
restart_timers:
    in r18, SREG
    cli
    in r16, TCNT1L
    in r17, TCNT1H
    lds r20, timer1_interval
    lds r21, timer1_interval+1
    add r20, r16
    adc r21, r17
    sts next_timer1, r20
    sts next_timer1+1, r21
    ldi r20, low(PONG_PHASE)
    ldi r21, high(PONG_PHASE)
    add r20, r16
    adc r21, r17
    sts next_timer2, r20
    sts next_timer2+1, r21
    rcall arm_nearest_compare
    out SREG, r18
    ret

; Program OCR1A for whichever next deadline is earlier, using modular signed
; subtraction. Valid intervals are limited to <32768 cycles.
arm_nearest_compare:
    lds r16, next_timer1
    lds r17, next_timer1+1
    lds r18, next_timer2
    lds r19, next_timer2+1
    sub r16, r18
    sbc r17, r19
    sbrc r17, 7
    rjmp arm_t1
arm_t2:
    out OCR1AL, r18
    out OCR1AH, r19
    ret
arm_t1:
    lds r18, next_timer1
    lds r19, next_timer1+1
    out OCR1AL, r18
    out OCR1AH, r19
    ret

; Compare ISR only records due work and advances its absolute deadline.
timer1_compare_isr:
    push r16
    push r17
    push r18
    push r19
    in r16, SREG
    push r16
    in r16, TCNT1L
    in r17, TCNT1H
    ; Is timer1 deadline due? signed(now-next1) >= 0
    lds r18, next_timer1
    lds r19, next_timer1+1
    sub r16, r18
    sbc r17, r19
    sbrc r17, 7
    rjmp check_timer2
    ldi r16, 1
    sts pending1, r16
    lds r16, timer1_interval
    lds r17, timer1_interval+1
    add r18, r16
    adc r19, r17
    sts next_timer1, r18
    sts next_timer1+1, r19
check_timer2:
    in r16, TCNT1L
    in r17, TCNT1H
    lds r18, next_timer2
    lds r19, next_timer2+1
    sub r16, r18
    sbc r17, r19
    sbrc r17, 7
    rjmp timer_isr_done
    ldi r16, 1
    sts pending2, r16
    lds r16, timer2_interval
    lds r17, timer2_interval+1
    add r18, r16
    adc r19, r17
    sts next_timer2, r18
    sts next_timer2+1, r19
timer_isr_done:
    rcall arm_nearest_compare
    pop r16
    out SREG, r16
    pop r19
    pop r18
    pop r17
    pop r16
    reti

; Start a pending line only when the previous line has completed. Configuration
; validation guarantees this branch is never late for an accepted schedule.
start_pending_message:
    lds r16, tx_busy
    tst r16
    brne start_done
    lds r16, pending1
    tst r16
    breq try_pending2
    clr r16
    sts pending1, r16
    ldi r30, low(string1)
    ldi r31, high(string1)
    lds r17, string1_len
    rjmp begin_tx
try_pending2:
    lds r16, pending2
    tst r16
    breq try_diagnostic
    clr r16
    sts pending2, r16
    ldi r30, low(string2)
    ldi r31, high(string2)
    lds r17, string2_len
    rjmp begin_tx
try_diagnostic:
    lds r16, diag_pending
    tst r16
    breq start_done
    clr r16
    sts diag_pending, r16
    ldi r30, low(err_string)
    ldi r31, high(err_string)
    ldi r17, 5
begin_tx:
    sts tx_ptr, r30
    sts tx_ptr+1, r31
    sts tx_left, r17
    ldi r16, 1
    sts tx_busy, r16
    in r16, UCSRB
    ori r16, (1<<UDRIE)
    out UCSRB, r16
start_done:
    ret

usart_udre_isr:
    push r16
    push r30
    push r31
    lds r16, tx_left
    tst r16
    breq tx_finished
    lds r30, tx_ptr
    lds r31, tx_ptr+1
    ld r16, Z+
    out UDR, r16
    sts tx_ptr, r30
    sts tx_ptr+1, r31
    lds r16, tx_left
    dec r16
    sts tx_left, r16
    rjmp tx_done
tx_finished:
    clr r16
    sts tx_busy, r16
    in r16, UCSRB
    andi r16, 0xff-(1<<UDRIE)
    out UCSRB, r16
tx_done:
    pop r31
    pop r30
    pop r16
    reti

; Receive a line into rx_buf. Parsing and validation belong in foreground.
usart_rx_isr:
    push r16
    push r17
    push r30
    push r31
    in r16, UDR
    lds r17, rx_len
    cpi r16, 13
    breq rx_end
    cpi r16, 10
    breq rx_end
    cpi r17, STRING_CAPACITY-1
    brsh rx_done
    ldi r30, low(rx_buf)
    ldi r31, high(rx_buf)
    add r30, r17
    adc r31, r1
    st Z, r16
    inc r17
    sts rx_len, r17
    rjmp rx_done
rx_end:
    ; A zero-length line is ignored. A nonempty line is marked by bit 7.
    tst r17
    breq rx_done
    ori r17, 0x80
    sts rx_len, r17
rx_done:
    pop r31
    pop r30
    pop r17
    pop r16
    reti

; Commands: R, T1=<cycles>, T2=<cycles>, S1=<up to 6 bytes>, S2=<...>.
; Reception is in an ISR; parsing below is foreground work, so Timer1 runs.
process_complete_command:
    lds r17, rx_len
    sbrs r17, 7
    ret
    andi r17, 0x7f
    clr r16
    sts rx_len, r16
    ; Stage both active intervals before changing just one of them.
    lds r18, timer1_interval
    lds r19, timer1_interval+1
    sts cand_timer1, r18
    sts cand_timer1+1, r19
    lds r18, timer2_interval
    lds r19, timer2_interval+1
    sts cand_timer2, r18
    sts cand_timer2+1, r19
    ldi ZL, low(rx_buf)
    ldi ZH, high(rx_buf)
    ld r16, Z+
    cpi r16, 'R'
    breq command_restart
    cpi r16, 'T'
    breq command_timer
    cpi r16, 'S'
    breq command_string
    rjmp command_bad
command_bad:
    ; An invalid command has not changed active timing parameters.
    ldi r16, 1
    sts diag_pending, r16
    ret
command_restart:
    cpi r17, 1
    brne command_bad
    rcall restart_timers
    ret
command_timer:
    cpi r17, 4
    brlo command_bad
    ld r18, Z+
    cpi r18, '1'
    breq timer_is_1
    cpi r18, '2'
    brne command_bad
    ldi r19, 2
    rjmp timer_have_number
timer_is_1:
    ldi r19, 1
timer_have_number:
    ld r18, Z+
    cpi r18, '='
    brne command_bad
    subi r17, 3
    rcall parse_u16_decimal
    brcs command_bad
    cpi r19, 1
    breq stage_timer1
    sts cand_timer2, r20
    sts cand_timer2+1, r21
    rjmp validate_and_commit
stage_timer1:
    sts cand_timer1, r20
    sts cand_timer1+1, r21
    rjmp validate_and_commit
command_string:
    cpi r17, 4
    brlo command_bad
    ld r18, Z+
    cpi r18, '1'
    breq string_is_1
    cpi r18, '2'
    brne command_bad
    ldi r19, 2
    rjmp string_copy
string_is_1:
    ldi r19, 1
string_copy:
    ld r18, Z+
    cpi r18, '='
    brne command_bad
    subi r17, 3
    tst r17
    breq command_bad
    cpi r17, 7
    brsh command_bad
    cpi r19, 1
    breq copy_s1
    ldi XL, low(string2)
    ldi XH, high(string2)
    sts string2_len, r17
    rjmp copy_payload
copy_s1:
    ldi XL, low(string1)
    ldi XH, high(string1)
    sts string1_len, r17
copy_payload:
    ld r16, Z+
    st X+, r16
    dec r17
    brne copy_payload
    ret
; Parse r17 ASCII decimal bytes at Z into r20:r21. Reject 0 and >=32768.
parse_u16_decimal:
    clr r20
    clr r21
decimal_loop:
    tst r17
    breq decimal_done
    ld r16, Z+
    subi r16, '0'
    cpi r16, 10
    brsh decimal_error
    mov r22, r21
    ldi r18, 10
    mul r20, r18
    mov r20, r0
    mov r21, r1
    mul r22, r18
    add r21, r0
    clr r1
    add r20, r16
    adc r21, r1
    sbrc r21, 7
    rjmp decimal_error
    dec r17
    rjmp decimal_loop
decimal_done:
    mov r16, r20
    or r16, r21
    breq decimal_error
    clc
    ret
decimal_error:
    sec
    ret

; Fixed phase=960 and payload capacity<=6 => lines reserve at most 960 clocks.
; The high level reserves an 800-cycle ERR line, so periods are >=2880.
; The timing condition remains gcd(periods)>=1920.
validate_and_commit:
    lds r20, cand_timer1
    lds r21, cand_timer1+1
    lds r22, cand_timer2
    lds r23, cand_timer2+1
    cpi r21, high(2880)
    brlo validate_bad
    brne check_t2_min
    cpi r20, low(2880)
    brlo validate_bad
check_t2_min:
    cpi r23, high(2880)
    brlo validate_bad
    brne calc_gcd
    cpi r22, low(2880)
    brlo validate_bad
calc_gcd:
    ; Euclid by subtraction; operands are bounded to 15 bits and interrupts
    ; remain on, so Timer1 is never stopped while this executes.
gcd_loop:
    cp r20, r22
    cpc r21, r23
    breq gcd_done
    brcs gcd_b_larger
    sub r20, r22
    sbc r21, r23
    rjmp gcd_loop
gcd_b_larger:
    sub r22, r20
    sbc r23, r21
    rjmp gcd_loop
gcd_done:
    cpi r21, high(1920)
    brlo validate_bad
    brne commit_candidate
    cpi r20, low(1920)
    brlo validate_bad
commit_candidate:
    in r16, SREG
    cli
    lds r18, cand_timer1
    lds r19, cand_timer1+1
    sts timer1_interval, r18
    sts timer1_interval+1, r19
    lds r18, cand_timer2
    lds r19, cand_timer2+1
    sts timer2_interval, r18
    sts timer2_interval+1, r19
    out SREG, r16
    rcall restart_timers
    ret
validate_bad:
    rjmp command_bad
