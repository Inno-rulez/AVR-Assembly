#define __SFR_OFFSET 0
#include "avr/io.h"

;================================================================
; RAM flags and counters
;================================================================
.section .data
t2_ovf_count: .byte 1     ; Timer2 overflow counter
wrong_count:  .byte 1     ; Wrong code entry counter

;================================================================
; Code section & vector table
;================================================================
.section .text
.global main

.org 0x0000
    rjmp main

.global __vector_5
.set    __vector_5, PCINT2_ISR

.global __vector_9
.set    __vector_9, TIMER2_OVF_ISR

;================================================================
; Keypad mapping (in flash)
;================================================================
row1_digits:  .byte 1, 2, 3, 10
row2_digits:  .byte 4, 5, 6, 11
row3_digits:  .byte 7, 8, 9, 12
row4_digits:  .byte 15, 0, 14, 13

;================================================================
; Reset / Initialization
;================================================================
main:
    ; Initialize stack pointer
    ldi r16, hi8(RAMEND)
    out SPH, r16
    ldi r16, lo8(RAMEND)
    out SPL, r16

    ; Configure ports
    ldi r21, 0xFF
    out DDRB, r21            ; PORTB all outputs
    ldi r20, 0xF0
    out DDRD, r20            ; PD4–PD7 rows, PD0–PD3 columns
    ldi r19, 0x07
    out DDRC, r19            ; PC0–PC2 outputs
    sbi PORTC, 1             ; Turn “correct” LED off
    sbi PORTC, 3             ; Enable pull-up resistor

    ; Idle keypad rows (ground PD4–PD7)
    ldi r20, 0x0F
    out PORTD, r20

    ; Wait for any key release
wait_release:
    in r21, PIND
    andi r21, 0x0F
    cpi r21, 0x0F
    brne wait_release

    ; Initialize Timer1 for Servo PWM (Fast PWM mode 14)
    in r17, SREG
    cli
    ldi r16, (1<<COM1A1)|(1<<WGM11)
    sts TCCR1A, r16
    ldi r16, (1<<WGM13)|(1<<WGM12)|(1<<CS12)
    sts TCCR1B, r16
    ldi r17, hi8(1249)
    ldi r16, lo8(1249)
    sts ICR1H, r17
    sts ICR1L, r16
    out SREG, r17

    ; Enable pin change interrupt on PD0–PD3
    ldi r16, 0x0F
    sts PCMSK2, r16
    ldi r16, (1<<PCIF2)
    sts PCIFR, r16
    ldi r16, (1<<PCIE2)
    sts PCICR, r16

    ; Initialize digit counter
    ldi r17, 0

    ; Enable global interrupts
    sei

main_loop:
    ; Hold servo at ~0 degrees
    ldi r26, 30
    rcall servo_set_position
    rjmp main_loop

;================================================================
; PCINT2 ISR: Keypad scanning and decoding
;================================================================
PCINT2_ISR:
    ; Scan row1
    ldi r16, 0b01111111
    out PORTD, r16
    nop
    in r16, PIND
    andi r16, 0x0F
    cpi r16, 0x0F
    brne row1_col

    ; Scan row2
    ldi r16, 0b10111111
    out PORTD, r16
    nop
    in r16, PIND
    andi r16, 0x0F
    cpi r16, 0x0F
    brne row2_col

    ; Scan row3
    ldi r16, 0b11011111
    out PORTD, r16
    nop
    in r16, PIND
    andi r16, 0x0F
    cpi r16, 0x0F
    brne row3_col

    ; Scan row4
    ldi r16, 0b11101111
    out PORTD, r16
    nop
    in r16, PIND
    andi r16, 0x0F
    cpi r16, 0x0F
    brne row4_col

    ; No key pressed
    ldi r16, 0x0F
    out PORTD, r16
    reti

row1_col:
    ldi r30, lo8(row1_digits)
    ldi r31, hi8(row1_digits)
    rjmp find_digit
row2_col:
    ldi r30, lo8(row2_digits)
    ldi r31, hi8(row2_digits)
    rjmp find_digit
row3_col:
    ldi r30, lo8(row3_digits)
    ldi r31, hi8(row3_digits)
    rjmp find_digit
row4_col:
    ldi r30, lo8(row4_digits)
    ldi r31, hi8(row4_digits)
    rjmp find_digit

find_digit:
    lsr r16
    brcc digit_located
    lpm r20, Z+
    rjmp find_digit

digit_located:
    lpm r20, Z
    rcall code_store_digit
    lsl r20
    lsl r20
    out PORTB, r20
    ldi r16, 0x0F
    out PORTD, r16
    reti

;================================================================
; Code handling and verification
;================================================================
code_store_digit:
    inc r17
    cpi r17, 1
    breq code_sd1
    cpi r17, 2
    breq code_sd2
    cpi r17, 3
    breq code_sd3
    cpi r17, 4
    breq code_sd4
    rjmp code_exit

code_sd1:
    mov r23, r20
    rjmp code_exit
code_sd2:
    mov r27, r20
    rjmp code_exit
code_sd3:
    mov r28, r20
    rjmp code_exit
code_sd4:
    mov r29, r20

    ; Compare entered code
    cpi r23, 2
    brne code_wrong
    cpi r27, 0
    brne code_wrong
    cpi r28, 2
    brne code_wrong
    cpi r29, 5
    brne code_wrong

code_correct:
    sbi PORTC, 0
    cbi PORTC, 1

    ; Reset wrong attempt counter
    ldi r16, 0
    sts wrong_count, r16

    ldi r26, 92
    rcall servo_set_position
    call delay_open
    sbi PORTC, 1
    cbi PORTC, 0
    rjmp code_reset

code_wrong:
    ; Increment wrong_count
    lds r16, wrong_count
    inc r16
    sts wrong_count, r16

    ; Check if two wrong attempts
    cpi r16, 2
    breq alarm_loop

    ; Otherwise blink error 6 times
    ldi r18, 6
blink_loop:
    sbi PORTC, 1
    sbi PORTC, 2
    rcall delay_blink
    cbi PORTC, 2
    rcall delay_blink
    dec r18
    brne blink_loop
    rjmp code_reset

code_reset:
    ldi r17, 0

code_exit:
    ; Debounce key release
debounce_release:
    in r22, PIND
    andi r22, 0x0F
    cpi r22, 0x0F
    brne debounce_release
    reti

;================================================================
; Alarm state (wrong code entered twice)
;================================================================
alarm_loop:
    sbi PORTC, 2
    cbi PORTC, 1
    rcall delay_blink
    sbi PORTC, 1
    cbi PORTC, 2
    rcall delay_blink
    rjmp alarm_loop

;================================================================
; Servo control (Timer1 Fast PWM on PB1)
;================================================================
servo_set_position:
    ; Input: r26 = OCR1A value (pulse width)
    sts OCR1AH, r1
    sts OCR1AL, r26
    ret

;================================================================
; Timer2-based delay (interrupt-driven)
;================================================================
timer2_delay_setup:
    ; Setup Timer2 normal mode, prescaler 1024
    ldi r16, 0
    sts TCCR2A, r16
    ldi r16, (1<<CS22)|(1<<CS21)|(1<<CS20)
    sts TCCR2B, r16

    ; Clear overflow counter
    ldi r16, 0
    sts t2_ovf_count, r16

    ; Enable Timer2 overflow interrupt
    ldi r16, (1<<TOIE2)
    sts TIMSK2, r16
    sei
    ret

wait_timer2:
    sleep
    lds r16, t2_ovf_count
    cp r16, r24
    brlo wait_timer2

    ; Disable Timer2 interrupt
    ldi r16, 0
    sts TIMSK2, r16
    ret

;Wait allowing push bitton bypass
wait2_bypass:
    sleep

    ; Check bypass button (PC3 low = pressed)
    in r17, PINC
    sbrs r17, PC3
    rjmp bypass_now

    ; Check overflow counter
    lds r16, t2_ovf_count
    cp r16, r24
    brlo wait2_bypass
bypass_now:
    ret

;================================================================
; Fixed delays wrappers
;================================================================
;3 s delay via timer2
delay_open:
    ldi r24, 183
    rcall timer2_delay_setup
    rcall wait2_bypass
    ret

;1/4 s delay (2 blinks per second) via timer2+
delay_blink:
    ldi r24, 15
    rcall timer2_delay_setup
    rcall wait_timer2
    ret

;================================================================
; Timer2 overflow ISR
;================================================================
TIMER2_OVF_ISR:
    lds r16, t2_ovf_count
    inc r16
    sts t2_ovf_count, r16
    reti

;================================================================
; End of file
;================================================================
