/* SPDX-License-Identifier: GPL-2.0-only */
.section .vectors,"ax"
.global _start
_start:
    bri start
    nop

.section .text,"ax"
start:
    mts rmsr, r0
    addik r1, r0, __stack_top
    addik r5, r0, __bss_start
    addik r6, r0, __bss_end
1:
    cmpu r7, r5, r6
    beqi r7, 2f
    swi r0, r5, 0
    addik r5, r5, 4
    bri 1b
    nop
2:
    brlid r15, main
    nop
3:
    bri 3b
    nop
