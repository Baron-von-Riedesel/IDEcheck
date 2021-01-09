
;--- direct video output for DOS

__vio_crt_adr equ 463h
__vio_cols    equ 44Ah
__vio_pagesta equ 44Eh
__vio_curpos0 equ 450h
__vio_page    equ 462h
__vio_rows    equ 484h

bs      equ 08
tab		equ 09

@getcursorpos macro
        movzx   ebx,byte ptr @flat:[__vio_page]
        mov     bx,@flat:[EBX*2+__vio_curpos0]
        endm

@setcursorpos macro
        movzx   ebx,byte ptr @flat:[__vio_page]
        mov     @flat:[EBX*2+__vio_curpos0],ax
        endm

        .CODE

VioSetCurPosDir proto stdcall :dword, :dword

VioPutCharDir proc stdcall char:dword

local   cols:dword
local   rows:dword

        pushad
        mov     ch,@flat:[__vio_rows]               ;rows-1
        mov     cl,@flat:[__vio_cols]               ;columns
        movzx   esi,word ptr @flat:[__vio_pagesta]  ;video page start
        @getcursorpos
        mov     dx,@flat:[__vio_crt_adr]
        cmp     dl,0D4h
        mov     edx,0B8000H
        jz      @F
        xor     dx,dx
@@:
        add     esi,edx                          ;esi=current start
        movzx   eax,ch
        movzx   ecx,cl                           ;ecx=no of cols
        mov     rows,eax
        mov     cols,ecx
        movzx   eax,bh                           ;eax=current row
        movzx   ebx,bl
        mul     cl
        add     eax,ebx
        shl     eax,1
        mov     ebx,eax                          ;ebx=current offset
        mov     eax,char

        cmp     al,cr
        jnz     ppch21
        mov     eax,ebx
        shr     eax,1
        div     cl
        mov     al,ah
        xor     ah,ah
        add     eax,eax
        sub     ebx,eax
        mov     al,cr
        jmp     ppch3
ppch21:
        cmp     al,lf
        jnz     ppch1
        add     ebx,ecx
        add     ebx,ecx
        jmp     ppch3
ppch1:
        cmp     al,bs
        jnz     ppch11
        and     ebx,ebx
        jz      ppch4
        sub     ebx,2
        jmp     ppch4
ppch11:
        cmp     al,tab
        jnz     ppch1x
        mov     eax,ebx           ;screen pointer / bytes per row
        shr     eax,1
        div     cl
                                  ;rest is position in row
        mov     al,' '
@@:
        call    writechar
        inc     ah
        test    ah,07
        jnz     @B
        jmp     ppch3
ppch1x:
        call    writechar
ppch3:
        mov     eax,rows
        inc     eax
        mul     ecx
        add     eax,eax           ;eax=max offset
        cmp     ebx,eax
        jc      ppch4
        mov     eax,rows
        call    scrollscreen
        mov     ebx,eax
ppch4:
        mov     eax,ebx
        mov     ecx,cols
        shr     eax,1
        div     cl                ;AX/CL
        movzx   ecx,ah            ;ecx=column
        movzx   eax,al            ;eax=row
        invoke  VioSetCurPosDir,ecx,eax
        popad
        ret
        align 4
writechar::
        mov     @flat:[ebx+esi],al
        inc     ebx
        inc     ebx
        retn
        align 4
VioPutCharDir endp

;*** scroll text screen
;*** ecx=no of columns
;*** eax=no or rows - 1

scrollscreen  proc near
        mov   ebx,esi           ;save address 1. row
        cld
        mov   edi,esi           ;edi -> start 1. row
        mov   esi,ecx
        add   esi,esi
        add   esi,edi           ;esi -> start 2. row

        mul   ecx

        xchg  ecx,eax
        shr   ecx,1             ;2 bytes/cell
        rep   movsd
        xchg  ecx,eax

        mov   esi,edi
        mov   eax,07200720h
        shr   ecx,1
        rep   stosd
        mov   eax,esi

        sub   eax,ebx           ;offset -> eax
        ret
        align 4
scrollscreen endp

VioSetCurPosDir proc stdcall uses ebx col:dword, row:dword

        mov     dx,@flat:[__vio_crt_adr]
        mov     ah,byte ptr row
        mov     al,byte ptr col
        @setcursorpos
        mov     bh,byte ptr @flat:[__vio_cols] ;cols
        mov     bl,al
        mov     al,ah
        mul     bh
        movzx   ebx,bl
        add     eax,ebx         ;is offset
        movzx   ecx,word ptr @flat:[__vio_pagesta];start video text page
        shr     ecx,1
        add     eax,ecx
        mov     cl,al           ;write high byte into crt 0Eh
        mov     al,0eh
        out     dx,ax
        mov     ah,cl           ;then low byte into crt 0Fh
        mov     al,0fh
        out     dx,ax
        ret
        align 4
VioSetCurPosDir endp

VioGetCurPosDir proc stdcall uses ebx

        @getcursorpos
        movzx   eax,bh
        shl     eax,16
        mov     al,bl
        ret
        align 4
VioGetCurPosDir endp

