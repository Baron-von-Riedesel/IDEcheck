
;--- idecheck 
;--- reads HDs on with Int13, PIO and DMA access method
;--- assemble with JWasm/Masm v6

	.386
	.MODEL FLAT
	option casemap:none
	option proc:private

?SETINT08 equ 0	;grab timer IRQ
?SETINT09 equ 0	;grab keyboard IRQ
?SETINT13 equ 1	;grab int 13h if PIO/DMA (protected-mode only)
?SETHDIRQ equ 0	;grab HD IRQ (problem with native controllers!)
?NTSUPP   equ 1 ;support running on NT (use IDECKVDD.DLL)
?BIOSHD   equ 0 ;1=rely on 0040:0075 to contain # of HDs
?SETINDOS equ 1 ;1=set inDOS flag if /PIO or /DMA is active

@flat	equ <ds>
cr		equ 13
lf		equ 10
fIRQ	equ 48Eh	;address of "IRQ happened" flag

;--- macros

CStr macro string:vararg
local sym
	.const
sym	db string,0
    .code
	exitm <offset sym>
endm

@dbgprintf macro fmt,args:vararg
ifdef _DEBUG
	.const
dbgfmtstr = $
	db fmt,0
	.code
 ifnb <args>
	invoke printf,dbgfmtstr,args
 else
	invoke printf,dbgfmtstr
 endif
endif
endm

;--- structures

DAP struct
bSize		db ?	;size of structure
bRes		db ?	;reserved
wNumSec		dw ?	;sectors to transfer
dwBuffer	dd ?	;transfer buffer SSSS:OOOO
union
dqStartSector dq ?
struct
dwStartLow	dd ?	;start sector low
dwStartHigh	dd ?	;start sector high
ends
ends
;dqAddr		dq ?	;EDD 3.0: 64bit flat transfer buffer address if dwBuffer is FFFF:FFFF
DAP ends

EDD struct
wSize	dw ?	;+0
wFlags	dw ?	;+2
dwCyl	dd ?	;+4
dwHeads	dd ?	;+8
dwSecs	dd ?	;+12
qwNumSecs dq ?	;+16
wSecSiz	dw ?	;+24
EDD ends

EDD20 struct
		EDD <>
lpCfg	dd ?	;far16 ptr config parameter
EDD20 ends

EDD30 struct
		EDD20 <>
wSig	dw ?			;+1E
bLength db ?			;+20 length of path
		db 3 dup (?)	;	 reserved
szBus	db 4 dup (?)	;+24 ( actually, just a 4-byte string, no termination )
szIFType db 8 dup (?)	;+28
qwIFPath db 8 dup (?)	;+30
szDevPath db 8 dup (?)	;+38
		db ?			;+40
bChecksum db ?			;+41
		db 8 dup (?)	;+42
EDD30 ends

;--- start of DPTE structure

DPTE struct
wIDEBase	dw ?	;IDE port base
wIDEAlt		dw ?	;alternate control port
bFlags		db ?	;drive flags (bit 4=1 -> drive is slave)
			db ?	;proprietary info
bIRQ		db ?	;IRQ for drive
DPTE ends

;*** DPMI real-mode call structure

RMCS struct
union
rEDI	dd ?	;+0
rDI		dw ?
ends
union
rESI	dd ?	;+4
rSI		dw ?
ends
union
rEBP	dd ?	;+8
rBP		dw ?
ends
RESERVE dd ?	;+12
union
rEBX	dd ?	;+16
rBX 	dw ?
ends
union
rEDX	dd ?	;+20
rDX 	dw ?
ends
union
rECX	dd ?	;+24
rCX		dw ?
ends
union
rEAX	dd ?	;+28
rAX		dw ?
ends
rFlags	dw ?	;+32
rES 	dw ?	;+34
rDS 	dw ?	;+36
rFS 	dw ?	;+38
rGS 	dw ?	;+40  
union
rCSIP	dd ?	;+42
struct
rIP 	dw ?
rCS 	dw ?
ends
ends
union
rSSSP	dd ?	;+46
struct
rSP 	dw ?
rSS 	dw ?
ends
ends
RMCS ends

;--- internal DRVPARM structure

DRVPARM struct
wIDEBase	dw ?
bSelFlag	db ?
bIRQ		db ?
DRVPARM ends

	include identify.inc

	.CONST

;*** constants

szAbout db 'IDECHECK 1.57 (C) 1995-2025 Japheth',lf
	db 'usage: IDECHECK drive [ options ]',lf
	db lf
	db ' drive: HD number, starts with 0',lf
	db ' options:',lf
	db '  /S:n - read n sectors/command (default 127, max. 256/128/128 for PIO/DMA/I13)',lf
	db '  /M:n - set multiple sector (PIO only, default is current value)',lf
	db "  /B:n - start read at sector n",lf
	db '  /L:n - stop after n sectors',lf
	db '  /U:n - set UDMA mode (DMA only)',lf
	db '  /I13 - use Int 13h (default)',lf
	db '  /PIO - use PIO',lf
	db '  /DMA - use DMA (requires PCI 2.0c BIOS and Busmaster DMA controller)',lf
	db '  /CHS - prefer CHS if LBA is available',lf
	db '  /IGN - continue on errors',lf
	db '  /16  - use 16bit INSW to read, not 32bit INSD (PIO only)',lf
	db "  /NOI - use polling, not IRQ (PIO/DMA only, /I:n ignored)",lf
	db "  /NOS - don't scan drive, just display info",lf
	db "  /SGL - do not use multiple read (PIO only, /M:n ignored)",lf
	db "  /REP - always read the same block (stop with ESC, /L:n ignored)",lf
	db "  /RES - reboots machine after program termination",lf
	db "  /LF  - print LF after CR",lf
	db "  /P:n - set base port of ISA IDE-controller (PIO/DMA only, defaults 1F0/170)",lf
	db "  /I:n - set irq-line of ISA IDE-controller (PIO/DMA only, defaults 14/15)",lf
	db "  ESC will stop HD checking",lf
	db lf
	db "IDECHECK should be run in true DOS for reliable results.",lf
	db "Additionally, no disk-cache programs should be loaded.",lf
nulls db 0

regtxt1 db '   Sector',lf
		db '---------',lf
	db 00
regtxt2 db '  Cyl Head Sec',lf
		db '--------------',lf
	db 00

szOk 	db "ok",lf,0
szFail	db "failed",lf,0

szDiverr	db "error",0
szTimeout	db "timeout error",0
szCmderr	db "command error. ",0
szNotrdy	db "device not ready error",0
szSecnotfnd	db "sector not found",0
szBadsector	db "bad sector",0
szEccerror	db "unrecoverable ECC error",0

drvtab label DRVPARM
		DRVPARM <1F0h, 0h, 14>
		DRVPARM <1F0h,10h, 14>
s2p1	DRVPARM <170h, 0h, 15>
s2p2	DRVPARM <170h,10h, 15>

;--- values for bFlags variable

FL_REP		equ 01h	;/REP set
FL_CHS		equ 02h	;/CHS set - use CHS mode
FL_RES		equ 04h	;/RES set - reboot after program termination
FL_UDMASET	equ 08h	;/U:x set - UDMA mode has been modified (temporarily)

;--- values for bMode variable
FM_I13		equ 0
FM_PIO		equ 1
FM_DMA		equ 2

	.DATA

flatsel dd 0		; flat DATA selector

bDrive	db -1		; drive number parameter 0,1,2,...
drvmask db 0		; PIO/DMA: 0 for master, 10h for slave
bMode	db FM_I13	; disk access method
bFlags	db 0		; flags

stacyl	dw 0000h	;for CHS
stahead db 00		;for CHS
stasec	db 01		;for CHS

	align 4

maxdrv	dd 0
maxcyl	dd -1		;max value for C in C/H/S
maxhead dd -1		;max value for H in C/H/S
maxsec	dd -1		;max value for S in C/H/S

dwDMAList dd 0		;linear address DMA list (must be in DOS mem)

bufadr	dd 0		;DOS memory buffer (128 kB)
bufadr2	dd 0		;64 kB buffer, aligned at 64 kB boundary
dwPath	  dd -1
dwClass   dd -1		;PCI class/subclass/PI
wPrimary  dw 1F0h
wSecondary dw 170h
dwIDEport dd -1		;IDE port
dwDMAPort dd -1
if ?NTSUPP
hVDD	dd -1
dwBopSel dd 0
endif
lasttick dd 0

numsec	dd 127	;numbers of sectors to read in one call
chssecs dq 0	;number of sectors in CHS mode
lbasecs dq 0	;number of sectors in LBA mode
cursec	dd 0	;current sector number to read (also set by /B:)
maxsecs dd 0	;max # of sectors ( either CHS or LBA )
sectors dd 0	;sectors read so far
reqsecs dd 0	;/L:xxx value
startsec dd 0	;/B:xxx value
numerr  dd 0
numrest dd 0
rmStack dd 0	;real mode stack SSSS:0000 address

if ?SETINDOS
InDOS	df 0	;indos flag address
endif
if ?SETHDIRQ
ohdirq	df 0
endif
if ?SETINT08
oint08	df 0
endif
if ?SETINT09
oint09	df 0
endif
if ?SETINT13
oint13	df 0
endif

OS_DOS equ 0
OS_NT  equ 1
OS_W9X equ 2
OS_OS2 equ 3

fCont	db 0		; continue on errors?
fLBA	db 0		; use LBA?
fDMA	db 0		; DMA is ok
fMult	db 1		; use multi-sector reads (PIO)
fLF 	db 0		; print LF after error display?
fUseIRQ db 1		; /NOI switch
f32 	db 1		; prefer to use INSD for PIO
fNoScan db 0		; /NOS option
fMSaved db 0		; PIC status saved flag
multsec db 1		; no of sectors to read for multiple sector read
reqmult db 0		; /M:xx value
oldmult db 0		; saved previous value for multiple sector
last1x1 db 0		; value IDE port x+1
last1x7 db 0		; value IDE port x+7
irqno	db -1		; IRQ for HD
irqm1	db 0		; saved value of MPIC
irqm2	db 0		; saved value of SPIC
seccnt	db 0		; sector count value
udmamode db -1		; ultra DMA mode to use
bInt13Ext db 0		; int 13h extension version returned by ah=41h
fStop	db 0		; stop request (ESC pressed)
bOS		db OS_DOS	; 0=DOS,1=NT,2=Win9x,3=OS2

	.DATA?

configb db 200h dup (?)	;buffer for configuration sector (PIO/DMA)

timesta db 4 dup (?)	;time in format hh:mm:ss:hs
timeend db 4 dup (?)	;time in format hh:mm:ss:hs
timedif db 4 dup (?)	;time in format hh:mm:ss:hs
ideregs db 5 dup (?)

	.CODE

;--- printf, preserves all registers

	include printf.inc

digtest proc
	cmp al,'0'
	jc wrong
	cmp al,'9' + 1
	jc ok1
	cmp cl,10
	jbe wrong
	or al,20h
	cmp al,'a'
	jc wrong
	cmp al,'g'
	jnc wrong
	sub al,'a'-10
	and al,al
	ret
ok1:
	sub al,'0'
	and al,al
	ret
wrong:
	stc
	ret
	align 4
digtest endp

;--- eax->string
;--- cl=base

getnumber proc uses ebx esi
	mov esi,eax
	xor ebx,ebx
	movzx ecx,cl
	xor edx,edx
nextdigit:
	lodsb
	call digtest
	jc getnum1
	inc ebx
	movzx eax,al
	push eax
	mov eax,edx
	mul ecx
	pop edx
	add edx,eax
	jmp nextdigit
getnum1:
	cmp ebx,1
	jc @F
	cmp al,1
	cmc
@@:
	mov eax,edx
	ret
	align 4
getnumber endp

_getdec proc stdcall pStr:ptr byte

	mov cl,10
	mov eax,pStr
	call getnumber
	ret
	align 4
_getdec endp

_gethex proc stdcall pStr:ptr byte

	mov cl,16
	mov eax,pStr
	call getnumber
	ret
	align 4
_gethex endp

;--- check if option is known and valid

getoption proc near
	mov eax,[ebx]
	or eax,00202020h
	cmp eax,"shc"		  ;/CHS
	jz o_chs
	cmp eax,"ngi"		  ;/IGN
	jz o_ign
	cmp eax,"lgs"		  ;/SGL
	jz o_sgl
	cmp eax,"ion"		  ;/NOI
	jz o_noi
	cmp eax,"son"		  ;/NOS
	jz o_nos
	cmp eax,"per"		  ;/REP
	jz o_rep
	cmp eax,"ser"		  ;/RES
	jz o_res
	cmp eax,"oip"		  ;/PIO
	jz o_pio
	cmp eax,"amd"		  ;/DMA
	jz o_dma
	cmp eax,"31i"		  ;/I13
	jz o_i13

	mov eax,[ebx]
	and eax,0FFFFFFh
	or ax,2020h
	cmp eax,"61"		  ;/16
	jz o_16
	cmp eax,"fl"		  ;/LF
	jz o_lf

	cmp ax,":b"
	jz o_b
	cmp ax,":i"
	jz o_i
	cmp ax,":l"
	jz o_l
	cmp ax,":m"
	jz o_m
	cmp ax,":p"
	jz o_p
	cmp ax,":s"
	jz o_s
	cmp ax,":u"
	jz o_u
getoption_er:
	stc
	ret
o_chs:
	or bFlags, FL_CHS
	ret
o_ign:
	or byte ptr fCont,1
	ret
o_sgl:
	mov fMult,0
	ret
o_16:
	mov byte ptr f32,0
	ret
o_lf:
	mov byte ptr fLF,1
	ret
o_noi:
	mov fUseIRQ,0
	ret
o_nos:
	mov fNoScan,1
	ret
o_dma:
	mov [bMode], FM_DMA
	ret
o_i13:
	mov [bMode], FM_I13
	ret
o_pio:
	mov [bMode], FM_PIO
	ret
o_rep:
	or [bFlags], FL_REP
	ret
o_res:
	or [bFlags], FL_RES
	ret
o_b:						;/B:xx option
	inc ebx
	inc ebx
	invoke _getdec, ebx
	jc getoption_er
	and eax,eax
	jz getoption_er
	mov [cursec],eax
	mov [startsec],eax
	ret
o_i:						;/I:xx option
	inc ebx
	inc ebx
	invoke _getdec, ebx
	jc getoption_er
	cmp eax,10h
	jnb getoption_er
	mov [irqno],al
	clc
	ret
o_l:						;/L:xx option
	inc ebx
	inc ebx
	invoke _getdec, ebx
	jc getoption_er
	and eax,eax
	jz getoption_er
	mov [reqsecs],eax
	ret
o_m:						;/M:xx option
	inc ebx
	inc ebx
	invoke _getdec, ebx
	jc getoption_er
	test eax,0FFFFFF00h
	jnz getoption_er
	and al,al
	jz getoption_er
	mov reqmult,al
	ret
o_p:						;/P:xx option
	inc ebx
	inc ebx
	invoke _gethex, ebx
	jc getoption_er
	mov [dwIDEport],eax
	ret
o_s:						;/S:xx option
	inc ebx
	inc ebx
	invoke _getdec, ebx
	jc getoption_er
	mov [numsec],eax
	ret
o_u:						;/U:xx option
	inc ebx
	inc ebx
	invoke _getdec, ebx
	jc getoption_er
	cmp eax,8
	jnb getoption_er
	mov [udmamode],al
	clc
	ret
	align 4
getoption endp

;--- get parameters
;--- return with C if an error occured

getparam proc c

local	dwErr:dword
local	parm[64]:byte
local	szCmdLine[128]:byte

	mov ah,51h
	int 21h
	push ds
	mov ds,ebx
	mov esi,80h
	lodsb
	and al,7Fh
	movzx ecx,al
	lea edi,szCmdLine
	rep movsb
	mov al,0
	stosb
	pop ds

	mov dwErr,offset szAbout

	lea esi,szCmdLine
	lea ebx, parm
	xor ah, ah
nextitem:
	mov al,[esi]
	cmp al,' '
	jz @F
	cmp al,9
	jz @F
	.if (al == 0)
@@:
		.if (ah)
			mov byte ptr [ebx],0
			lea ebx, parm
			pushad
			mov al,[ebx]
			cmp al,'-'
			jz @F
			cmp al,'/'
@@:
			.if (ZERO?)
				inc ebx
				call getoption
			.else
				.if (bDrive == -1)
					invoke _getdec, ebx
					mov [bDrive],al
				.else
					stc
				.endif
			.endif
			popad
			jc getpar_er
		.endif
		mov ah,0
		cmp al,0
		jz done
	.else
		mov [ebx],al
		inc ah
		inc ebx
	.endif
	inc esi
	jmp nextitem
done:
	cmp [bDrive],-1
	jz getpar_er
	mov eax,[numsec]
	mov ecx,256
	cmp [bMode],FM_PIO	;for PIO, 256 sectors are allowed
	jz @F
	mov ecx,128			;for DMA and I13, 128 is max
@@:
	cmp eax,ecx
	ja err1
	clc
	ret
err1:
	invoke printf, CStr("This mode limits sectors set with /S to %u",lf), ecx
	stc
	ret
getpar_er:
parerr2:
	invoke printf, CStr("%s"), dwErr
	stc
	ret
	align 4
getparam endp

;--- set multi sector (for PIO)
;--- AL=value set by /M:x

setmult1 proc c

	mov ebx,offset configb
	mov bx,[ebx+2*47]
	cmp al,bl
	jnbe setmult1_er
	mov edx,[dwIDEport]
	add edx,2
	out dx,al
	call setdrive
	call waitready
	jc setmult1_er2
	mov al,0C6h
	out dx,al
	call waitcmd
	jc setmult1_er2
	in al,dx
	test al,1
	jnz setmult1_er2
	clc
	ret
setmult1_er2:
	invoke printf, CStr("cannot set multiple sector mode",lf)
	stc
	ret
setmult1_er:
	invoke printf, CStr("requested multiple sector value is invalid",lf)
	stc
	ret
	align 4
setmult1 endp

;--- for DMA and PIO: wait for IDE controller to get ready
;--- inp:dwIDEport 
;--- out:C on errors, DX=status port

waitready proc near
	mov edx,[dwIDEport]
	add edx,7
	mov ecx,200000h
@@:
	in al,dx
	and al,0C0h
	cmp al,40h
	jz @F
	call checkifescpressed
	loopz @B
	stc
	ret
@@:
	clc
	ret
	align 4
waitready endp

;--- inp: DX=IDE status port (base+7)
;--- returns in AL:

waitdata proc near

	mov ecx,200000h
	test [fUseIRQ], 1
	jnz waitdata_1
@@:
	in al,dx
	test al,08h
	jnz @F
	call checkifescpressed
	loopz @B
	in al,dx
waitdata_er:
	stc
	ret
@@:
	clc
	ret
waitdata_1::
@@:
	test byte ptr @flat:[fIRQ],80h
	jnz waitdata_ex
	in al,61h
	loop @B
	stc
	ret
waitdata_ex:
	mov byte ptr @flat:[fIRQ],0
	in al,dx
	clc
	ret
	align 4
waitdata endp

waitseek proc near
	mov ecx,100000h
	test [fUseIRQ], 1
	jnz waitdata_1
@@:
	in al,dx
	test al,10h
	jnz @F
	loop @B
waitseek_er:
	stc
	ret
@@:
	clc
	ret
	align 4
waitseek endp

waitcmd proc near
	test [fUseIRQ], 1
	jnz waitdata
	mov ecx,10000h
@@:
	in al,dx
	and al,0C0h
	cmp al,40h
	loopnz @B
	in al,dx
	clc
	ret
waitcmd_er:
	stc
	ret
	align 4
waitcmd endp

;--- get multiple sector setting for PIO,DMA
;--- in: dwIDEport, drvmask

getmsetting proc near

	mov edx,[dwIDEport]
	add edx,2
	mov al,80h
	out dx,al		 ;1x2 sectors
	inc edx
	mov al,1		 ;1x3 start sec
	out dx,al
	inc edx
	xor ax,ax
	out dx,al		 ;1x4 cyl
	inc edx
	out dx,al		 ;1x5
	inc edx
	in al,dx
	and al,0A0h
	or al,[drvmask]
	out dx,al		 ;1x6
	call waitready
	jc getmsetting_er
	mov al,0C4h
	out dx,al
	call waitdata
	jc getmsetting_er
	test al,1				   ;multiple sector not set yet
	jnz getmsetting_ex1
@@:
	mov edx,[dwIDEport]
	add edx,2
	in al,dx
	mov ah,80h
	xchg al,ah
	sub al,ah
	movzx eax,al
	mov [oldmult],al
	invoke printf, CStr("checked: multiple sector value seems to be %u",lf), eax
	mov al,[oldmult]
	jz getmsetting_ex

	mov ecx,80h
	mov edx,[dwIDEport]
	add edx,7
getmsetting_2:
	mov esi,ecx
	mov ecx,800000h
@@:
	in al,dx
	test al,08
	jnz @F
	in al,61h
	loop @B
	jmp getmsetting_er
@@:
	mov ecx,100h
	mov edx,[dwIDEport]
@@:
	in ax,dx
	loop @B
	add edx,7
	mov ecx,esi
	loop getmsetting_2
getmsetting_ex:
	clc
	ret
getmsetting_ex1:
	invoke printf, CStr("multiple sector value not set yet",lf)
	clc
	ret
getmsetting_er:
	stc
	ret
	align 4
getmsetting endp

;--- set "multiple sectors"

setmult proc c

	mov ebx,offset configb
	mov al,[ebx].IDENTIFY_DEVICE_DATA.CurrentMultiSectorSetting
	bt word ptr [ebx].IDENTIFY_DEVICE_DATA.SupportedFlags,MultiSectorSettingValid
	jnc setmult_0
	and al,al
	jnz @F
setmult_0:
	call getmsetting
	jc setmult_er
@@:
if 0
	mov ebx,offset configb
	mov al,[ebx+2*59]
	and al,al
	jnz setmult_1
	invoke printf, CStr(lf,"WARNING: original multiple sector value is unknown",lf)
	invoke printf, CStr("and therefore cannot be restored. You should reboot your",lf)
	invoke printf, CStr("computer after program termination to avoid problems.",lf)
	invoke printf, CStr("Continue? [Y/es or N/o] ")
@@:
	mov ah,10h
	int 16h
	or al,20h
	cmp al,'n'
	stc
	jz setmult_ex
	cmp al,'y'
	jnz @B
	invoke _crout
setmult_1:
endif
	mov al,[reqmult]
	call setmult1
	jc setmult_ex
	mov al,[reqmult]
	mov [multsec],al
	mov fMult,1
	movzx eax,al
	invoke printf, CStr("multiple sectors set to %u",lf), eax
	clc
setmult_ex:
	ret
setmult_er:
	invoke printf, CStr("fatal error, will terminate",lf)
	stc
	ret
	align 4
setmult endp

;*** position to cylinder 0

setcyl0 proc near
	call setdrive
	mov edx,[dwIDEport]
	add edx,2
	xor al,al
	out dx,al			 ;1x2
	inc edx
	out dx,al			 ;1x3
	inc edx
	out dx,al			 ;1x4
	inc edx
	out dx,al			 ;1x5
	call waitready		 ;1x7
	jc @F
	mov al,70h
	out dx,al
	call waitseek
	test al,1
	jnz @F
	clc
	ret
@@:
	stc
	ret
	align 4
setcyl0 endp

setdrive proc near
	mov edx,[dwIDEport]
	add edx,6
	in al,dx
	and al,0EFh
	or al,[drvmask]
	or al,0A0h
	out dx,al
	inc edx
	ret
	align 4
setdrive endp

checkstate proc near
	call setdrive
	call waitready
	jc checkstate_ex
	mov ecx,10000h
	mov edx,[dwIDEport]
checkstate_1:
	add edx,7
	in al,dx
	test al,8
	jz checkstate_ex
	sub edx,7
	in ax,dx
	loop checkstate_1
	stc
checkstate_ex:
	ret
	align 4
checkstate endp

;*** read all partition tables with int 13 CHS call.
;*** this causes some caches to flush buffers

readpartition proc near
	mov dl,[bDrive]
	or dl,80h
	mov ecx,[maxdrv]
	jecxz done
@@:
	push edx
	push ecx
	mov cx,1
	mov dh,0
	mov ax,0201h
	call int13acc	;will be read into 128k buffer
	pop ecx
	pop edx
	inc dl
	loop @B
done:
	ret
	align 4
readpartition endp

;--- convert IRQ to INT
;--- todo: adjust for modified IRQ bases

getirq proc
	mov al,[irqno]
	cmp al,8
	jb @F
	add al,70h-8
	ret
@@:
	add al,8
	ret
	align 4
getirq endp

;--- set mask for HD irq in PICs

setirqmask proc
	mov cl,[irqno]
	cmp cl,8
	mov dx,0A1h
	jnb @F
	mov dx,021h
@@:
	mov ah,1
	and cl,7
	shl ah,cl
	xor ah,0FFh
	in al,dx
	and al,ah
	out dx,al
	cmp dl,21h
	jz @F
	in al,21h
	and al,0FBh
	out 21h,al
@@:
	ret
	align 4
setirqmask endp

SetIntVectors proc stdcall
if ?SETINT08
	mov bl, 8
	mov ax, 204h
	int 31h
	mov dword ptr [oint08+0], edx
	mov word ptr [oint08+4], cx
	mov ecx, cs
	mov edx, offset i08rou
	mov ax, 205h
	int 31h
endif
if ?SETINT09
	mov bl, 9
	mov ax, 204h
	int 31h
	mov dword ptr [oint09+0], edx
	mov word ptr [oint09+4], cx
	mov ecx, cs
	mov edx, offset i09rou
	mov ax, 205h
	int 31h
endif
	cmp bMode, FM_I13
	jz done
if ?SETINT13	; hook int 13h when reading DMA/PIO?
	mov bl, 13h
	mov ax, 204h
	int 31h
	mov dword ptr [oint13+0], edx
	mov word ptr [oint13+4], cx
	mov ecx, cs
	mov edx, offset i13rou
	mov ax, 205h
	int 31h
endif

	in al, 021h
	mov [irqm1], al
	in al, 0A1h
	mov [irqm2], al
	mov [fMSaved], 1
	mov al, 0FFh
	out 0A1h,al
	mov al, 0FCh
	out 021h, al

	test [fUseIRQ], 1
	jz done
if ?SETHDIRQ
	call getirq
	mov bl, al
	mov ax, 204h
	int 31h
	mov dword ptr [ohdirq+0], edx
	mov word ptr [ohdirq+4], cx
	mov ecx, cs
	mov edx, offset irqrou
	mov ax, 205h
	int 31h
endif
	call setirqmask	;set mask for HD irq
done:
	ret
	align 4
SetIntVectors endp

;--- since int 1A may need more than 512 bytes stack
;--- dont call it directly

int1A proc
	push ebp
	mov ebp,esp
	sub esp,34h - 32
	pushad
	mov eax, rmStack
	mov [ebp-34h].RMCS.rSSSP, eax
	mov [ebp-34h].RMCS.rFlags, 202h
	mov edi, esp
	mov bx, 01Ah
	mov cx, 0
	mov ax, 300h
	int 31h
	mov ah,byte ptr [ebp-34h].RMCS.rFlags
	sahf
	popad
	mov esp,ebp
	pop ebp
	ret
	align 4
int1A endp

;--- find path of IDE controllers
;--- programming interface
;--- bit 7: busmaster
;--- bit 4-6: reserved
;--- bit 0-1: primary IDE
;--- bit 2-3: secondary IDE
;--- in: dwIDEport 
;--- out: [dwPath]=bus/dev/fn

FindPath proc uses esi
	cmp dwIDEport, -1
	jnz @F
	invoke printf, CStr("No IDE port to find device path",lf)
	stc
	ret
@@:
	mov esi, 80000008h
nextdev:
	mov dx, 0cf8h
	mov eax, esi
	out dx, eax
	add dl, 4
	in eax, dx
	shr eax, 8
	mov bl, al
	and al, 80h
	cmp eax, 10180h
	jz devfound
skipdev:
	add esi, 80h
	cmp esi, 81000008h
	jb nextdev
	stc
	ret
devfound:
	mov eax, 1F0h
	test bl, 1
	jz @F
	mov eax, esi
	mov al, 4*4
	mov dx, 0cf8h
	out dx, eax
	add dl, 4
	in eax, dx
	and al, 0feh
@@:
	cmp eax, [dwIDEport]
	jz found2
	mov eax, 170h
	test bl, 4
	jz @F
	mov eax, esi
	mov al, 6*4
	mov dx, 0cf8h
	out dx, eax
	add dl, 4
	in eax, dx
	and al, 0feh
@@:
	cmp eax, [dwIDEport]
	jnz skipdev
found2:
	mov eax, esi
	shr eax, 8
	movzx eax, ax
	mov [dwPath],eax
	clc
	ret
	align 4
FindPath endp

if 1

;--- check if AHCI mode is enabled in SATA controller

checksata proc uses ebx esi edi

	push 9
	call getpcireg ;get PCI 24 - HBA
	jc exit
	mov esi, ecx
	invoke printf, CStr("SATA HBA=%X",lf), ecx
	push esi
	pop cx
	pop bx
	mov si,0000h
	mov di,1000h
	mov ax,0800h
	int 31h
	jc exit
	push bx
	push cx
	pop esi

	mov ebx, [esi+4]
	mov ecx, CStr("dis")
	bt ebx, 31
	jz @F
	mov ecx, CStr("en")
@@:
	invoke printf, CStr("Global HBA Control (GHC): %X [AHCI mode %sabled]",lf), ebx, ecx
	bt ebx, 31
	jnc exit
	mov ebx, [esi+0]
	invoke printf, CStr("HBA Caps (CAP): %X",lf), ebx
;	xor eax, eax
;	bt ebx, 18
;	setc al
;	invoke printf, CStr("CAP bit 18[SAM]=%u (1=supports AHCI mode only)",lf), eax
;	invoke printf, CStr("Interrupt Status Register (IS): %X",lf), dword ptr [esi+8]
;	invoke printf, CStr("Ports Implemented (PI): %X",lf), dword ptr [esi+12]
	invoke printf, CStr("AHCI Version (VS): %X",lf), dword ptr [esi+16]
	stc
exit:
	ret
getpcireg:
	pop eax
	pop edi
	push eax
	shl edi,2
	mov ax,0B10Ah
	mov ebx,[dwPath]
	call int1A
	retn
checksata endp
endif

;--- get and display PCI infos
;--- out: NC=ok
;---      C=no PCI IDE controller

GetPCIInfo proc

	cmp [dwPath],-1
	jnz @F
	call FindPath
	jc exit
@@:
	cmp [dwPath],0	;invalid value returned by EDD BIOS?
	stc
	jz exit
	push 0
	call getpcireg
	jc error
	movzx eax,cx
	shr ecx,16
	invoke printf, CStr("PCI %04X (%2u): vendor ID=%X, device ID=%X",lf), dwPath, edi, eax, ecx
	push 1
	call getpcireg
	jc error
	movzx eax,cx
	shr ecx,16
	mov edx, offset nulls
	test al,4
	jnz @F
	mov edx, CStr("no ")
@@:
	invoke printf, CStr("PCI %04X (%2u): command register=%X[%sbusmaster], status register=%X",lf), dwPath, edi, eax, edx, ecx
	test al,4
	jnz @F
	cmp [bMode], FM_DMA
	jnz @F
	invoke printf, CStr("Busmaster (bit 2) not enabled in command register! /DMA can't work",lf)
	stc
	ret
@@:
	push 2
	call getpcireg ;get PCI 08-0B
	jc error
	movzx eax,cl
	shr ecx,8
	mov [dwClass],ecx ;contains 0B=BCC,0A=SCC,09=PI
	invoke printf, CStr("PCI %04X (%2u): revision ID=%X, class code=%X",lf), dwPath, edi, eax, dwClass
	mov eax,[dwClass]
	mov dl,al
	shr eax,8
	.if (eax != 0101h)	;class storage+IDE?
		.if ah == 1
			.if al == 0
				mov ecx,CStr("SCSI")
			.elseif ( al == 2)
				mov ecx,CStr("floppy")
			.elseif ( al == 4)
				mov ecx,CStr("RAID")
			.elseif ( al == 5)
				mov ecx,CStr("ATA")
			.elseif ( al == 6)
				.if dl == 1
					mov byte ptr [dwClass], 8Fh
					call checksata
					jnc ahci_disabled
					mov ecx,CStr("SATA (AHCI)")
				.else
					mov ecx,CStr("SATA")
				.endif
			.elseif ( al == 7)
				mov ecx,CStr("SAS")
			.else
				mov ecx,CStr("unknown")
			.endif
			invoke printf, CStr("%s controller.",lf), ecx
		.elseif ( ah == 0Ch && al == 3 )
			movzx eax,dl
			invoke printf, CStr("USB device, %02X (00=UHCI,10=OHCI,20=EHCI,30=XHCI)",lf), eax
		.else
			invoke printf, CStr("PCI device's BCC (=Base Class Code) != 01 (mass storage device)",lf)
		.endif
		cmp [bMode], FM_I13
		jz exit
		stc
		jmp exit
	.endif
ahci_disabled:
if 0
	push 3
	call getpcireg ;get PCI 0C-0F
	jc error
	mov esi, ecx
	shr esi, 24
	mov edx, ecx
	shr edx, 16
	movzx edx, dl
	mov eax, ecx
	shr eax, 8
	movzx eax, al
	movzx ecx, cl
	invoke printf, CStr("PCI %04X (%2u): cache line size=%X, latency=%X, header type=%X, selftest=%X",lf), dwPath, edi, ecx, eax, edx, esi
endif
	test byte ptr [dwClass],80h	;busmaster?
	.if (ZERO?)
		invoke printf, CStr("IDE controller does NOT support Busmaster DMA!",lf)
		jmp exit
	.endif

	test byte ptr [dwClass],1	;primary: legacy or native?
	jz @F
	push 4
	call getpcireg	;base addr 0 (IDE primary base)
	jc error
	and cl,0F8h
	mov [wPrimary],cx
	invoke printf, CStr("PCI %04X (%2u): Primary base address 0=%X ",lf), dwPath, edi, ecx
if 1
	push 5
	call getpcireg
	jc error
	and cl,0F8h
	invoke printf, CStr("PCI %04X (%2u): Primary base address 1=%X",lf), dwPath, edi, ecx
endif
@@:
	test [dwClass],4	;secondary: native or legacy?
	jz @F
	push 6
	call getpcireg	;base port 2 (IDE secondary base)
	jc error
	and cl,0F8h
	mov [wSecondary],cx
	invoke printf, CStr("PCI %04X (%2u): Secondary base address 0=%X",lf), dwPath, edi, ecx
if 1
	push 7
	call getpcireg
	jc error
	and cl,0F8h
	invoke printf, CStr("PCI %04X (%2u): Secondary base address 1=%X",lf), dwPath, edi, ecx
endif
@@:
	push 8
	call getpcireg	;base DMA controller
	jc error
	and cl,0F0h		;bus master IO port is 16 byte
	cmp [dwDMAPort],-1
	jnz dma_is_set
	mov eax,[dwIDEport]
	cmp ax,[wPrimary]
	jz @F
	add ecx,8
@@:
	mov [dwDMAPort], ecx
dma_is_set:
	invoke printf, CStr("PCI %04X (%2u): Busmaster DMA controller port base=%X",lf), dwPath, edi, ecx

	test [dwClass],1	;Primary legacy?
	jz @F
	push 15
	call getpciregb
	jc error
	movzx ecx, cl
	mov [irqno],cl
	invoke printf, CStr("PCI %04X (%2u): interrupt line (IRQ)=%X",lf), dwPath, edi, ecx
@@:
	push 21
	call getpciregb
	jc error
	invoke printf, CStr("PCI %04X (%2u): UDMA-Control=%X (b0=PM,b1=PS,b2=SM,b3=SS)",lf), dwPath, edi, ecx
@@:
exit:
	ret
error:
	invoke printf, CStr("PCI AX=B10A, EBX=%X, EDI=%X failed",lf), ebx, edi
	stc
	ret
	align 4

getpcireg:
	pop eax
	pop edi
	push eax
	shl edi,2
	mov ax,0B10Ah
	mov ebx,[dwPath]
	call int1A
	retn
	align 4
getpciregb:
	pop eax
	pop edi
	push eax
	shl edi,2
	mov ax,0B108h
	mov ebx,[dwPath]
	call int1A
	retn
	align 4

GetPCIInfo endp

;--- display CHS/LBA information from config sector
;--- ebx=config data

DisplayCfgValues proc
	movzx eax,[ebx].IDENTIFY_DEVICE_DATA.NumCylinders
	movzx ecx,[ebx].IDENTIFY_DEVICE_DATA.NumHeads
	movzx edx,[ebx].IDENTIFY_DEVICE_DATA.NumSectorsPerTrack
	mov [maxcyl], eax
	mov [maxhead], ecx
	mov [maxsec], edx
	invoke printf, CStr("CFG 1/3/6: C/H/S: %u/%u/%u - "), eax, ecx, edx

	mov eax,[maxsec]
	mul [maxhead]
	mul [maxcyl]
	mov dword ptr [chssecs+0],eax
	mov dword ptr [chssecs+4],edx
	invoke printf, CStr("%lu sectors",lf), edx::eax

	test [fLBA],1
	jz @F
	mov eax,[ebx].IDENTIFY_DEVICE_DATA.UserAddressableSectors
	mov dword ptr [lbasecs+0],eax
	mov dword ptr [lbasecs+4],0
	invoke printf, CStr("CFG  60: LBA sectors: %u",lf), eax
	bt [ebx].IDENTIFY_DEVICE_DATA.AdditionalSupported, ExtendedUserAddressableSectorsSupported
	.if CARRY?
		invoke printf, CStr("CFG 230: LBA sectors: %lu",lf), [ebx].IDENTIFY_DEVICE_DATA.ExtendedNumberOfUserAddressableSectors
	.endif
@@:
	ret
	align 4
DisplayCfgValues endp

;--- set [maxsecs] variable
;--- called by getint13parms & parprot

setmaxsecs proc
	mov eax,dword ptr [lbasecs]
	cmp dword ptr lbasecs+4,0
	jz @F
	mov eax,-1
@@:
	test [fLBA],1
	jnz @F
	mov eax,dword ptr [chssecs]
@@:
;	sub eax,[cursec]	;do we start at sector 0 or is /B:xxx set?
;	jnc done
;	xor eax, eax
done:
	mov [maxsecs],eax
	cmp [reqsecs],0
	jz @F
	mov ecx,[cursec]
	add ecx,[reqsecs]
	cmp eax, ecx
	jb @F
	mov [maxsecs],ecx
@@:
	ret
	align 4
setmaxsecs endp

;--- set HD parameters for DMA and PIO if no EDD is available
;--- works for legacy IDE controllers (1F0h, 170h) only

sethdparms proc
	movzx eax,[bDrive]
	cmp al,4
	cmc
	jc exit
	mov ebx,sizeof DRVPARM
	mul ebx
	lea ebx,[eax+drvtab]
	movzx eax,[ebx].DRVPARM.wIDEBase
	movzx edx,[ebx].DRVPARM.bSelFlag
	movzx ecx,[ebx].DRVPARM.bIRQ
	mov [dwIDEport],eax
	mov [drvmask],dl
	mov [irqno],cl
	invoke printf, CStr("assuming legacy IDE controller, ATA port base=%X, device=%X, IRQ=%u",10), eax, edx, ecx
	clc
exit:
	ret
	align 4
sethdparms endp

;--- get int 13h info for drive in [bDrive]
;--- flags returned in CL by int 13h, ah=41h:
;--- 0: Int13, ah=42h, 43h, 48h supported
;--- 1: removable functions supported
;--- 2: EDD supported

getint13parms proc
	mov ah,41h
	mov bx,55AAh
	xor ecx,ecx
	mov dl,[bDrive]
	or dl,80h
if ?NTSUPP
	cmp [hVDD],-1
	jz @F
;	call int13
	mov bInt13Ext,2
	mov cl,4
	jmp int13ext
@@:
endif
	int 13h
	jc @F
	cmp bx,0AA55h
	jnz @F
	mov bInt13Ext,ah
	movzx eax,ah
	movzx ecx,cx
	push ecx
	invoke printf, CStr("Int 13 extensions: version=%X, API support bitmap=%X",lf), eax, ecx
	pop ecx
	test cl,1		;int 13h, ah=42h/43h available?
	jnz int13ext
@@:
	or bFlags, FL_CHS
;	test cl,4
;	jnz int1348ok
noint1348:
	mov ah,08h
	call int13acc
	jc error
	movzx edx,dh		;max head number
	mov ax,cx
	mov ecx,edx		;ecx ok
	movzx edx,al
	and dl,3Fh		;edx ok
	shr al,6
	xchg al,ah
	movzx eax,ax		;eax ok
	pushad
	mul edx
	mul ecx
	mov dword ptr [chssecs+0],eax
	mov dword ptr [chssecs+4],0
	mov dword ptr lbasecs+0,eax
	mov dword ptr lbasecs+4,0
	popad
	invoke printf, CStr("Int 13: cylinder/head/sector: %u/%u/%u",lf), eax, ecx, edx
	invoke printf, CStr("Int 13: sectors: %lu",lf), lbasecs
	jmp done

int13ext:
	mov [fLBA], 1
;	test cl,4		;int 13h, ah=48h available?
;	jz noint1348
int1348ok:
	xor ecx,ecx
	mov cl,sizeof EDD
	cmp bInt13Ext, 20h
	jb @F
	mov cl,sizeof EDD20
	cmp bInt13Ext, 30h
	jb @F
	mov cl,sizeof EDD30
@@:
	mov ebx, [bufadr]
	mov dword ptr @flat:[ebx].EDD.wSize,ecx
	mov ah,48h
	call int13acc
	jc error
	mov ebx, [bufadr]
	mov eax, dword ptr @flat:[ebx].EDD.qwNumSecs+0
	mov edx, dword ptr @flat:[ebx].EDD.qwNumSecs+4
	mov dword ptr lbasecs+0, eax
	mov dword ptr lbasecs+4, edx
	mov dword ptr chssecs+0, eax
	mov dword ptr chssecs+4, edx
	cmp @flat:[ebx].EDD.wSize,sizeof EDD20
	jb noedd20
	cmp @flat:[ebx].EDD20.lpCfg,-1
	jz nodpte
	movzx eax,word ptr @flat:[ebx].EDD20.lpCfg+0
	movzx edx,word ptr @flat:[ebx].EDD20.lpCfg+2
	shl edx,4
	add edx,eax
	movzx eax,@flat:[edx].DPTE.wIDEBase
	cmp [dwIDEport],-1
	jnz @F
	and eax,eax
	jz @F
	mov [dwIDEport],eax
	invoke printf, CStr("EDD20: IDE base port: %X",lf), eax
@@:
	mov al,@flat:[edx].DPTE.bFlags
	and al,010h
	mov [drvmask],al
	mov al,@flat:[edx].DPTE.bIRQ
	and al,al
	jz @F
	mov [irqno],al
	movzx eax,al
	invoke printf, CStr("EDD20: IDE IRQ: %u",lf), eax
nodpte:
@@:
	cmp @flat:[ebx].EDD.wSize,sizeof EDD30
	jb noedd30
	push 0
	push dword ptr @flat:[ebx].EDD30.szBus
	invoke printf, CStr("EDD30: bus: %s",lf), esp
	add esp, 2*4
	mov eax,dword ptr @flat:[ebx].EDD30.szBus
	cmp eax," ICP"
	jnz noedd30
	mov eax,dword ptr @flat:[ebx].EDD30.szIFType+0
	mov ecx,dword ptr @flat:[ebx].EDD30.szIFType+4
	mov dword ptr [configb+0],eax
	mov dword ptr [configb+4],ecx
	invoke printf, CStr("EDD30: interface type: %s",lf), addr configb
	cmp [bMode],FM_I13
	jz @F
	cmp eax," ATA"	;for /DMA and /PIO, interface MUST be "ATA" or "SATA"
	jz @F
	cmp eax,"ATA"
	jz @F
	cmp eax,"ATAS"
	jnz error2
@@:
	mov ax,word ptr @flat:[ebx].EDD30.qwIFPath
	mov cl,byte ptr @flat:[ebx].EDD30.qwIFPath+2
	xchg al,ah			;move bus to ah
	and cl,7			;function
	shl al,3
	or al,cl
	movzx eax,ax
	mov [dwPath],eax
	movzx eax, byte ptr @flat:[ebx].EDD30.qwIFPath+0
	movzx ecx, byte ptr @flat:[ebx].EDD30.qwIFPath+1
	movzx edx, byte ptr @flat:[ebx].EDD30.qwIFPath+2
	invoke printf, CStr("EDD30: interface path: %X/%X/%X",lf), eax, ecx, edx
	invoke printf, CStr("EDD30: device path: ")
	mov ecx,0
	.while ecx < 8
		movzx eax, byte ptr @flat:[ebx][ecx].EDD30.szDevPath
		push ecx
		invoke printf, CStr("%X "), eax
		pop ecx
		inc ecx
	.endw
	invoke printf, CStr(lf)
noedd30:
noedd20:
	movzx eax,@flat:[ebx].EDD.wSecSiz
	invoke printf, CStr("EDD: sector size: %u",lf), eax
	mov eax,dword ptr lbasecs+0
	mov edx,dword ptr lbasecs+4
	shrd eax,edx,11
	invoke printf, CStr("EDD: LBA sectors: %lu (%u MB)",lf), lbasecs, eax

	test @flat:[ebx].EDD.wFlags,2	;CHS info valid?
	jz done
	mov eax, @flat:[ebx].EDD.dwCyl
	mov ecx, @flat:[ebx].EDD.dwHeads
	mov edx, @flat:[ebx].EDD.dwSecs
	invoke printf, CStr("EDD: cylinder/head/sector: %u/%u/%u",lf), eax, ecx, edx
done:
	mov [maxcyl],eax
	mov [maxhead],ecx
	mov [maxsec],edx
	cmp [bMode], FM_I13
	jz @F
	cmp [dwIDEport],-1
	jnz @F
	call sethdparms
	jc error
@@:
	call setmaxsecs
	clc
	ret
error:
	movzx eax,[bDrive]
	invoke printf, CStr("drive %u invalid",lf), eax
	stc
	ret
error2:
	movzx eax,[bDrive]
	invoke printf, CStr("drive %u isn't (S)ATA",lf), eax
	stc
	ret
	align 4
getint13parms endp

;*** identify: read config sector

readid proc stdcall

	mov byte ptr @flat:[fIRQ],0
	call setdrive
	sti
	call waitready
	jc readid_er
	mov al,0ECh
	out dx,al
	call waitdata
	jc readid_er1
	test al,1
	jnz readid_er2
	mov edx,[dwIDEport]
	mov edi,offset configb
	cld
	cli
	mov ecx,100h
	rep insw
	sti
	clc
	ret
readid_er:
readid_er1:
readid_er2:
	stc
	ret
	align 4
readid endp

;*** display parameters, prepare 
;--- called by main

parprot proc stdcall

;	call getint13parms
;	jc exit

	xor edi,edi
	mov ax,0B101h
	call int1A
	jc nopci2
	cmp ah,0
	jnz nopci2
	cmp edx," ICP"
	jnz nopci2
	invoke printf, CStr("PCI v2.0c BIOS found",lf)
	call GetPCIInfo
	jnc pcidone
	invoke printf, CStr("no PCI IDE controller found",lf)
	jmp pcidone ; continue (/DMA will fail below, but PIO might be tried with port 1F0h/170h)
nopci2:
	invoke printf, CStr("no PCI v2.0c BIOS found",lf)
pcidone:
	cmp bMode, FM_DMA
	jnz @F
	cmp [dwDMAPort],-1
	jnz @F
	invoke printf, CStr("no PCI Busmaster IDE controller found",lf)
	stc
	ret
@@:
	cmp fNoScan,0
	jnz @F
	invoke printf, CStr("flushing cache ... ")
	mov ax,4A10h		   ;flush Cache
	mov bx,0001h
	int 2Fh
	invoke printf, addr szOk
	invoke printf, CStr("reading partition table ... ")
	call readpartition
	invoke printf, addr szOk
@@:
	call SetIntVectors

	cmp bMode, FM_I13
	jz exit

	call SaveDevStat

	invoke printf, CStr("waiting for device ready ... ")
	call checkstate
	jnc @F
	invoke printf, addr szFail
	jmp parprot_er
@@:
	invoke printf, addr szOk
	invoke printf, CStr("identify device ... ")
	call readid
	jnc @F
	invoke printf, addr szFail
	jmp parprot_er
@@:
	invoke printf, addr szOk
	cmp [fNoScan], 0
	jnz @F
	invoke printf, CStr("seek cylinder 0 ... ")
	call setcyl0
	.if CARRY?
		invoke printf, offset szFail
	.else
		invoke printf, offset szOk
	.endif
@@:
	mov ebx,offset configb
	mov ax,[ebx].IDENTIFY_DEVICE_DATA.Capabilities
	test ah,1
	setnz [fDMA]
	test ah,2
	setnz [fLBA]
	invoke DisplayCfgValues
	movzx edx, [ebx].IDENTIFY_DEVICE_DATA.Capabilities
	movzx ecx, [fDMA]
	movzx eax, [fLBA]
	invoke printf, CStr("CFG  49=%4X: DMA=%u, LBA=%u",lf), edx, ecx, eax

	test [bFlags], FL_CHS
	jz @F
	mov [fLBA], 0
	invoke printf, CStr("CFG: LBA not used",lf)
@@:

;--- PIO values

	mov ebx,offset configb
	movzx edx,word ptr [ebx+51*2]
	movzx eax, dh
	bsf eax,eax
	jnz @F
	mov eax,-1
@@:
	inc eax
	pushad
	invoke printf, CStr("CFG  51=%4X: PIO mode 0-2 timing: %u",lf), edx, eax
	popad

;--- PIO 32-bio IO?

parprot_4:
	test byte ptr [f32],1
	jnz @F
	invoke printf, CStr("16-Bit IO (INSW) will be used",lf)
@@:

;--- Advanced PIO modes

	movzx eax,word ptr [ebx+53*2]
	test al,2	;word at 64 valid?
	.if (ZERO?)
	   invoke printf, CStr("CFG  53=%4X: No Advanced PIO modes supported",lf), eax
	   jmp noapio
	.endif
	movzx ecx,byte ptr [ebx+64*2]
	invoke printf, CStr("CFG  64=%4X: Advanced PIO modes supported:"), ecx
	mov eax,3
	mov dl,[ebx+64*2]
	.while (dl)
		shr dl,1
		jnc @F
		pushad
		invoke printf, CStr(" %u"), eax
		popad
@@:
		inc eax
	.endw
	invoke printf, CStr(lf)
noapio:

;--- display (+set) multiple sector value

	mov ebx,offset configb
	movzx ecx, word ptr [ebx+2*47]
	movzx eax, cl
	invoke printf, CStr("CFG  47=%4X: max. multiple sector value: %u",lf), ecx, eax
	test [fMult],1
	jz nomultiple
	mov ebx,offset configb
	movzx ecx, word ptr [ebx+2*59]
	push ecx
	movzx eax, cl
	invoke printf, CStr("CFG  59=%4X: current multiple sector value: %u"), ecx, eax
	pop eax
	test ah,1
	jz parprot_3
	and al,al
	jz parprot_3
	mov multsec,al
	invoke printf, CStr(" (valid setting)",lf)
	jmp parprot_2
parprot_3:
	invoke printf, CStr(" (invalid setting)",lf)
	mov fMult,0
	cmp [reqmult],0
	jnz parprot_2
	invoke printf, CStr("won't use multiple sector read (try /M switch)",lf)
parprot_2:
	cmp [reqmult],0
	jz nomultiple
	push ebx
	call setmult
	pop ebx
	jc parprot_ex
nomultiple:

;--- multiword DMA modes

	movzx edx,word ptr [ebx+63*2]
	movzx edx,dx
	invoke printf, CStr("CFG  63=%4X: Multiword DMA modes supported:"), edx
	xor eax,eax
	mov dl,[ebx+63*2]
	.while (dl)
		shr dl,1
		jnc @F
		pushad
		invoke printf, CStr(" %u"), eax
		popad
@@:
		inc eax
	.endw
	pushad
	movzx edx,byte ptr [ebx+63*2+1]
	bsf eax,edx
	mov ecx, CStr(", active: none",lf)
	jz @F
	mov ecx, CStr(", active: %u",lf)
@@:
	invoke printf, ecx, eax
	popad

;--- UDMA modes

	movzx eax,word ptr [ebx+53*2]
	test al,4
	setnz cl
	movzx ecx,cl
	push ecx
	invoke printf, CStr("CFG  53=%4X: UDMA valid?[bit 2]=%u",lf), eax, ecx
	pop ecx
	and ecx,ecx
	jz noudma

	cmp bMode, FM_DMA
	jnz noudmaset
	cmp udmamode, -1
	jz noudmaset
	invoke printf, CStr("setting UDMA mode ... ")
	call setudmamode
	jnc @F
	invoke printf, addr szFail
	stc
	jmp parprot_ex
@@:
	invoke printf, addr szOk
noudmaset:

	movzx ecx,word ptr [ebx+88*2]
	invoke printf, CStr("CFG  88=%4X: UDMA modes supported:"), ecx
	xor eax,eax
	mov dl,[ebx+88*2]
	.while (dl)
		shr dl,1
		jnc @F
		pushad
		invoke printf, CStr(" %u"), eax
		popad
@@:
		inc eax
	.endw
	movzx edx,byte ptr [ebx+88*2+1]
	bsf eax,edx
	mov ecx, CStr(", active: %u", lf)
	jnz @F
	mov ecx, CStr(", active: none", lf)
@@:
	pushad
	invoke printf, ecx, eax
	popad
noudma:

;--- Write cache

	mov ebx,offset configb
	mov ax,[ebx+2*87]
	and ah,0C0h
	cmp ah,40h
	jnz nosupp
	mov ax,[ebx+2*85]
	mov ecx,CStr("enabled")
	test al,20h
	jnz @F
	mov ecx,CStr("disabled")
@@:
	invoke printf, CStr("CFG  85=%4X: Write cache: %s",lf), eax, ecx
nosupp: 

	call setmaxsecs
	clc
	jmp parprot_ex
parprot_er:
	invoke printf, CStr(lf,"device not available",lf)
	stc
parprot_ex:
	pushfd
	call RestoreDevStat
	popfd
exit:
	ret
	align 4
parprot endp

;*** set UDMA mode

setudmamode proc stdcall

	call setdrive
	call waitready
	jc error
	mov edx,[dwIDEport]
	add edx, 2		;address "sector count" register
	mov al,udmamode	;0-7
	or al,40h		;set UDMA mode
	out dx,al
	mov edx,[dwIDEport]
	add edx, 1
	mov al,03		;set transfer mode
	out dx,al
	mov edx,[dwIDEport]
	add edx, 7
	mov al,0EFh		;set features
	out dx,al
	call waitcmd
	jc error
	test al,1
	jnz error
	or [bFlags], FL_UDMASET
	clc
	ret
error:
	stc
	ret
	align 4
setudmamode endp

;*** set int 23h (ctrl-c)

setctl proc near
	push ds
	push cs
	pop ds
	mov ax,2523h
	mov edx,offset ir23
	int 21h
	pop ds
	ret
	align 4
setctl endp

ir23 proc
	iretd
	align 4
ir23 endp

if ?SETINT08
i08rou proc far
	push ds
	push eax
	mov ds,cs:[flatsel]
	inc dword ptr ds:[046Ch]
	mov al,20h
	out 20h,al
	pop eax
	pop ds
	sti
	iretd
	align 4
i08rou endp
endif

if ?SETINT09
i09rou proc far
	push eax
	in al,60h
	cmp al,1				;ESC pressed?
	jnz @F
	push ds
	mov ds,cs:[flatsel]
	or byte ptr [fStop],1
	pop ds
@@:
	mov al,20h
	out 20h,al
	pop eax
	sti
	iretd
	align 4
i09rou endp
endif

if ?SETINT13

IRETS struct
_eip	dd ?
_cs		dd ?
_efl	dd ?
IRETS ends

;--- protected-mode int 13h

i13rou proc far
	mov ah,80h
	or [esp].IRETS._efl,1	;set C
	iretd
	align 4
i13rou endp

endif

if ?SETHDIRQ
irqrou proc near
	push ds
	push eax
	mov ds,cs:[flatsel]
	mov byte ptr ds:[fIRQ],-1 
	mov al,20h
	cmp [irqno],8
	jnc @F
	out 0A0h,al
@@:
	out 20h,al
	pop eax
	pop ds
	sti
	iretd
	align 4
irqrou endp
endif

;*** set AL (=number of sectors to read) ***

setALreg proc near
	mov ebx,[maxsecs]
	sub ebx,[cursec]
	mov eax,[numsec]	;sectors to read in one call
	cmp ebx,eax
	jae @F
	mov eax,ebx
@@:
	ret
	align 4
setALreg endp

;--- CHS: set ecx, edx registers for next call of readcore
;--- LBA: set ebx
;--- out: C=done, NC=continue

prepregs proc c

	test fLBA, 1
	jnz prepregs_1
	test [bFlags], FL_REP
	jnz prepregs_1
	movzx eax,dl
	add eax,[numsec]
	mov ebx,[maxsec]
prepregs_0:
	cmp eax,ebx
	jna prepregs_01
	inc dh
	cmp dh,byte ptr [maxhead]
	jb @F
	mov dh,00
	inc ecx
@@:
	sub eax,ebx
	jmp prepregs_0
prepregs_01:
	mov dl,al
prepregs_1:
	mov ebx,[maxsecs]
	sub ebx,[cursec]
	jbe prepregs_2
prepregs_ex:
	clc
	ret
prepregs_2:
	stc
	ret
	align 4
prepregs endp

;--- returns NZ if ESC has been pressed
;--- reads char directly from keyboard buffer

checkifescpressed proc near


if ?SETINT09
	test byte ptr cs:[fStop],1
	ret
else

bufsta	 equ   41ah
bufend	 equ   41ch
ebufsta  equ   480h
ebufend  equ   482h

	push ebx
checkifescpressed_0:
	mov BX,@flat:[bufsta]
	cmp BX,@flat:[bufend]
	jz checkifescpressed_ex
	cli
	push eax
if 0;def __JWASM__
	mov AX,@flat:[BX+400h]   ; not accepted by Masm
else
	movzx ebx,bx
	mov AX,@flat:[EBX+400h]
endif
	INC EBX
	INC EBX
	CMP BX,@flat:[ebufend]
	JNZ @F
	MOV BX,@flat:[ebufsta]
@@:
	MOV @flat:[bufsta],BX
	sti
	cmp ah,01h
	pop eax
	jnz checkifescpressed_0
	or ebx, ebx		; reset Z flag
checkifescpressed_ex:
	pop ebx
	ret
endif
	align 4
checkifescpressed endp

checktime proc
    push eax
    mov eax, ds:[46Ch]
    push eax
    sub eax, [lasttick]
    cmp eax, 5
    pop eax
    jc @F
    mov [lasttick], eax
@@:
    pop eax
    ret
checktime endp

;*** read a hd until ESC is pressed or the end is reached

checkhd proc near

	cmp bMode, FM_I13
	jz @F
if ?SETINDOS
	push es
	les ebx,[InDOS]
	inc byte ptr es:[ebx]
	pop es
endif
	call SaveDevStat		;does low-level IDE access
@@:
	mov dl,[stasec] 	;sector   => dl   CHS addressing only
	mov cx,[stacyl] 	;cylinder => ch
	mov dh,[stahead]	;head	  => dh
check_0:
	push ecx
	push edx
	call setALreg		;set number of sectors to read in AL
	call readcore
	pop edx
	pop ecx
	jc check_1			;C if end has been reached
	call checktime
	jc nextblock
	call checkifescpressed
	jnz done
	call protocol
	jmp check_0a
check_1:
	mov eax, [numsec]
	cmp eax, 1
	jz @F
	@dbgprintf <10,"enter error mode (reading 1 sector/call",10>
	mov [numerr], eax
	mov [numrest], eax
	mov [numsec],1
	invoke printf, CStr(10)
    jmp check_0a
@@:
;	@dbgprintf <10,"error reading cursec=%u",10>, cursec
	invoke printf, CStr("error reading sector %u",10), cursec
	test byte ptr fCont,1   ;option /IGN set? (continue on errors)
	jnz done
	inc [cursec]
check_0a:
	cmp numerr,0
	jz nextblock
	dec numerr
	jnz nextblock
	mov eax,[numrest]
	mov [numsec],eax
	@dbgprintf <10,"exit error mode (reading %u sectors/call",10>,eax
nextblock:
	call prepregs
	jnc check_0
	@dbgprintf <"prepregs returned with C, [cursec]=%u [maxsecs]=%u",10>, cursec, maxsecs
done:
	cmp bMode, FM_I13
	jz exit
	call resetmultsec		;multiple sector reset
	cli
	call RestoreDevStat
if ?SETINDOS
	push es
	les ebx,[InDOS]
	dec byte ptr es:[ebx]
	pop es
endif
	sti
exit:
	ret
	align 4
checkhd endp

;--- call int 13h, AH=02/08/42/48 
;--- in: AX, CX (if AH=2), DX, [cursec]
;--- out: NC=ok, C=error
;--- for read/writes, the DOS 128 kB buffer will be used.
;--- currently limited to 2 TB access (32-bit sector count)

int13acc proc
	push edi
	push ebx
	push ebp
	mov ebp, esp
	sub esp, 34h
	mov [ebp-34h].RMCS.rAX, ax
	mov [ebp-34h].RMCS.rDX, dx
	mov [ebp-34h].RMCS.rSSSP, 0
	mov [ebp-34h].RMCS.rFlags, 202h
	cmp ah, 42h
	jz is42
	cmp ah, 02h
	jz is02
	cmp ah, 48h
	jz is48
	mov [ebp-34h].RMCS.rES, 0
	mov [ebp-34h].RMCS.rDI, 0
	jmp callit
is02:
	mov [ebp-34h].RMCS.rBX, 0
	mov [ebp-34h].RMCS.rCX, cx
	mov ecx, [bufadr2]
	shr ecx, 4
	mov [ebp-34h].RMCS.rES, cx
	jmp callit
is48:
	mov [ebp-34h].RMCS.rSI, 0
	mov ecx, [bufadr]
	shr ecx, 4
	mov [ebp-34h].RMCS.rDS, cx
	jmp callit
is42:
	mov ebx, [dwDMAList]
	mov ecx, [bufadr2]
	mov @flat:[ebx].DAP.bSize, sizeof DAP
	mov @flat:[ebx].DAP.bRes,0h
	mov ah,0
	mov @flat:[ebx].DAP.wNumSec,ax
if 1
	shl ecx, 12			;linear to SSSS:0000
	mov @flat:[ebx].DAP.dwBuffer,ecx
else
	mov @flat:[ebx].DAP.dwBuffer,-1
	mov dword ptr @flat:[ebx+0].DAP.dqAddr, ecx
	mov dword ptr @flat:[ebx+4].DAP.dqAddr, 0
endif
	mov eax,[cursec]
	mov @flat:[ebx].DAP.dwStartLow, eax
	mov @flat:[ebx].DAP.dwStartHigh, 0
	shr ebx, 4
	mov [ebp-34h].RMCS.rSI, 0
	mov [ebp-34h].RMCS.rDS, bx	;DS:SI -> DAP
callit:
	mov edi, esp
	mov bx, 13h
	mov cx, 0
if ?NTSUPP
	cmp hVDD,-1
	jnz handleNT
endif
	mov ax, 300h
	int 31h
doneNT:        
	mov edx,[ebp-34h].RMCS.rEDX
	mov ecx,[ebp-34h].RMCS.rECX
	mov ah,byte ptr [ebp-34h].RMCS.rFlags
	sahf
	mov eax,[ebp-34h].RMCS.rEAX
	mov esp,ebp
	pop ebp
	pop ebx
	pop edi
	ret
	align 4
if ?NTSUPP
handleNT:
	mov eax,hVDD
	push 2
	call RunBop		;DispatchCall
	jmp doneNT
	align 4
endif
int13acc endp

;--- read drive using int 13h
;--- CHS: AL=num sectors, DH=head, DL=start sector, CX=cylinder 
;--- LBA: al=num sectors

readi13 proc
	mov ah,dl
	mov dl,[bDrive]
	or dl,80h
	test fLBA, 1
	jnz use42
	xchg ch,cl		;cyl 0-7 -> CH
	shl cl,6		;cyl 8-9 -> CL[6-7]
	or cl,ah		;sector ->	CL[0-5]
	mov ah,02h
	jmp int13acc
use42:
	mov ah,42h
	jmp int13acc
	align 4
readi13 endp

;*** readcore ***
;*** in:
;*** for CHS: CX=cylinder, DH=Head, DL=Sector
;*** CHS + LBA: AL=secs
;--- cursec: current sector to start read
;*** out: NC -> EAX=sectors read
;---      var cursec updated
;***       C -> error

readcore proc near

	push ebp
	mov ebp,esp
	cmp bMode, FM_I13
	jnz noint13
	mov bh,al
	call readi13
	mov bl,0
	jnc readcore_3
	stc
	jmp readcore_ex
noint13:
	sub esp,4
	mov bh,dh
	dec al
	cmp bMode, FM_DMA
	jnz @F
	cmp al,80h
	jc @F
	mov al,7Fh			;max 127
@@:
	inc al
	mov bl,al

	mov [esp+0],al		;1x2 (sectors to read)

	test fLBA, 1		;use LBA access?
	jz readcore_1
	mov eax,[cursec]
	mov [esp+1],ax
	shr eax,16
	mov [esp+3],al

	mov al,ah
	and al,0Fh			;just 28 bits for sector address in LBA
	or al,[drvmask]
	or al,0A0h+40h		;bit 6 enables LBA
	jmp readcore_2
readcore_1:
	mov [esp+1],dl		;sector
	mov [esp+2],cx		;cylinder

	mov ah,bh			;head
	and ah,0Fh
	mov al,[drvmask]
	or al,0A0h
	or al,ah
readcore_2:
	mov edx,[dwIDEport]
	add dl,6
	out dx,al			;1x6=drive/head

	mov esi, esp
	mov cl,4
	mov edx,[dwIDEport]
	add dl,2
@@:
	outsb
	inc edx
	dec cl
	jnz @B

	mov bh,0		   ;sector count
	inc edx 		   ;1x7
	cmp bMode, FM_DMA
	jz @F
	call waitready
	jc readcore_er3
@@:
	mov edi,[bufadr]   ;the buffer is zero-based flat!

	cmp bMode, FM_DMA
	jnz @F
	push edx
	mov edx,[dwDMAPort]
	in al,dx
	and al,0F6h
	or al,8		   ;DMA read
	out dx,al

	add edx, 2
	in al,dx
	or al,6		;clear status	
	out dx,al

	add edx,2
	mov eax, [dwDMAList]
	out dx,eax

	pop edx
	mov al,0C8h 	   ;read multiple with DMA
	jmp setcmd
@@:
	mov al,0C4h 	   ;read multiple
	test fMult,1
	jnz setcmd
	mov al,20h		   ;read single
setcmd:
	out dx,al
readcore_0: 			   ;<----

	mov cl,[multsec]
	and bl,bl
	jz @F
	cmp cl,bl
	jb @F
	mov cl,bl
@@:
	cmp bMode, FM_DMA
	jnz polldata

	mov eax, [dwDMAList]
	mov edi,[bufadr2]
	mov @flat:[eax+0], edi
	push ecx
	movzx ecx, bl
	cmp bl,1
	adc ch,0
	shl ecx, 9
	bts ecx,31				;set end of list
	mov @flat:[eax+4], ecx
	pop ecx
if 0
	mov dh,3
	dec edx
@@:
	in al,dx
	test al,8
	jz @B
endif
	mov edx,[dwDMAPort]
	in al,dx
	or al,1
	out dx,al

	call waitdata

	mov cl,bl
	jmp @F
polldata:
	mov edx,[dwIDEport]
	add dl,7
	push ecx
	call waitdata
	pop ecx
	mov [last1x7],al
	jc readcore_er1
	and al,075h
	cmp al,50h
	jnz readcore_er2
@@:
	sub bl,cl
	movzx ecx,cl
	add bh,cl

	cmp bMode, FM_DMA
	jnz nodma

	mov edx,[dwDMAPort]
	in al,dx
	and al,not 1
	out dx,al

;	movzx eax,cl
;	shl eax,9
;	add edi, eax

	jmp readcore_3
nodma:
	mov edx,[dwIDEport]
	shl ecx,7	;*128 (128*4=512)
	cld
	test byte ptr [f32],1
	jnz @F
	shl ecx,1	;*256 (256*2=512)
	rep insw
	jmp readcore_3
	align
@@:
	rep insd
readcore_3:
	cmp bl,0
	jnz readcore_0		;----> next block of sectors
	movzx eax,bh
	and bh,bh
	jnz @F
	mov ah,01
@@:
	add [sectors],eax
	test bFlags, FL_REP
	jnz readcore_4
	add [cursec],eax
	jmp readcore_4
readcore_er3:						;device not ready
	mov al,3
	jmp readcore_er
readcore_er2:						;command error
	mov al,2
	jmp readcore_er
readcore_er1:						;timeout error (bit 3 von 1x7)
	mov al,1
	jmp readcore_er
readcore_er0:						;command not successful
	mov al,0
readcore_er:
	mov edx,[dwIDEport]
	inc dl
	push eax
	in al,dx
	mov [last1x1],al
	mov [seccnt],bh
	pop eax
	stc
	jmp readcore_ex
readcore_4:
	clc
readcore_ex:
	mov esp,ebp
	pop ebp
	ret
	align 4
readcore endp

;*** display protocol
;--- all registers + flags preserved!
;--- called by checkhd()
;--- note that inDOS flag is set if PIO/DMA
;--- and printf() is using DOS - to be fixed.

protocol proc c

	pushad
	pushfd

	lahf

	test [bFlags], FL_REP
	jnz protok_0
	test [fLBA], 1
	jnz protok_1
	call protoCHS
	jmp protok_2
protok_0:
	push eax
	invoke printf, CStr(13,"Sectors: %u"), [sectors]
	pop eax
	jmp protok_2
protok_1:
	push eax
	mov eax,[cursec]
    sub eax,[startsec]
	mov ecx, 100
	mul ecx
	mov ecx,[maxsecs]
    sub ecx,[startsec]
	div ecx
    push eax
    mov eax, edx   ;remainder
    mov ecx, 10
    mul ecx
    mov ecx,[maxsecs]
    sub ecx,[startsec]
    div ecx
    mov edx, eax
    pop eax
	invoke printf, CStr(13,"Sector: %u (%u.%u%%)"), [cursec], eax, edx
	pop eax
protok_2:
	test ah,1
	jnz protok_er
	test byte ptr [fLF],1
	jz protok_4
	jmp protok_3
protok_er:
	call errorout
protok_3:
	invoke printf, CStr(lf)
protok_4:

	popfd
	popad
	ret
	align 4
protocol endp

;*** display CHS protocol

protoCHS proc c

	push eax
	push ecx
	push edx
	movzx eax, dh	;H
	movzx edx, dl	;S
	invoke printf, CStr(13,"CHS: %5u/%3u/%2u"), ecx, eax, edx
	pop edx
	pop ecx
	pop eax
	ret
	align 4
protoCHS endp

;--- display error flags in AL
;--- modifies EBX

errorregout proc
	mov bl,al
	test bl,1
	jz @F
	invoke printf, CStr("DAM not found ")
@@:
	test bl,2
	jz @F
	invoke printf, CStr("track 0 not found ")
@@:
	test bl,4
	jnz @F
	invoke printf, CStr("command aborted ")
@@:
	test bl,10h
	jnz @F
	invoke printf, CStr("ID not found ")
@@:
	test bl,40h
	jz @F
	invoke printf, CStr("uncorrectable ECC error ")
@@:
	test bl,80h
	jz @F
	invoke printf, CStr("bad block detected ")
@@:
	ret
	align 4
errorregout endp

;--- modifies EAX, EBX

errorout proc near

	pushad
	movzx eax, [seccnt]
	movzx edx, [last1x1]
	invoke printf, CStr(" %02X %02X["), eax, edx
	mov al,[last1x1]
	call errorregout
	movzx eax,[last1x7]
	invoke printf, CStr("] %02X "), eax
	popad
	mov ebx,offset szDiverr
	cmp al,00
	jz @F
	mov ebx,offset szTimeout
	cmp al,01
	jz @F
	mov ebx,offset szCmderr
	cmp al,02
	jz @F
	mov ebx,offset szNotrdy
@@:
	push eax
	invoke printf, CStr("%s"), ebx
	pop eax
	cmp al,2
	jnz errorout_ex
	mov al,[last1x1]
	mov ebx,offset szSecnotfnd
	test al,10h
	jnz @F
	mov ebx,offset szEccerror
	test al,40h
	jnz @F
	mov ebx,offset szBadsector
	test al,80h
	jnz @F
	jmp errorout_ex
@@:
	invoke printf, CStr("%s"), ebx
errorout_ex:
	ret
	align 4
errorout endp

;--- reset multiple sector setting if it was changed

resetmultsec proc c
	mov al,[reqmult]
	and al,al
	jz exit
	mov ebx,offset configb
	mov al,[ebx+2*59]
	and al,al
	jnz @F
	mov al,[oldmult]
	and al,al
	jz exit
@@:
	call setmult1
exit:
	ret
	align 4
resetmultsec endp

SaveDevStat proc c
	pushad
	mov edx,[dwIDEport]
	add dl,2
	mov ecx,5
	mov edi,offset ideregs
	cld
@@:
	in al,dx
	stosb
	inc edx
	loop @B
	popad
	ret
	align 4
SaveDevStat endp

RestoreDevStat proc c
	pushad
	mov edx,[dwIDEport]
	add dl,2
	mov ecx,5
	mov esi,offset ideregs
	cld
@@:
	lodsb
	out dx,al
	inc edx
	loop @B
	popad
	ret
	align 4
RestoreDevStat endp

writetimestamp proc stdcall formstr:ptr byte

	movzx edi,dh
	movzx eax,dl
	movzx edx,ch
	movzx ecx,cl
	invoke printf, formstr, ecx, edx, eax, edi
	ret
	align 4
writetimestamp endp

ResetIntVectors proc near
if ?SETINT08
	xor ecx,ecx
	xchg cx,word ptr [oint08+4]
	jecxz @F
	mov edx,dword ptr [oint08+0]
	mov bl,8
	mov ax,205h
	int 31h
@@:
endif
if ?SETINT13
	xor ecx,ecx
	xchg cx,word ptr [oint13+4]
	jecxz @F
	mov edx,dword ptr [oint13+0]
	mov bl,13h
	mov ax,205h
	int 31h
@@:
endif
if ?SETHDIRQ
	xor ecx,ecx
	xchg cx,word ptr [ohdirq+4]
	jecxz @F
	mov edx,dword ptr [ohdirq+0]
	call getirq
	mov bl,al
	mov ax,205h
	int 31h
@@:
endif
	cmp [fMSaved], 0
	jz @F
	mov al,[irqm2]
	out 0A1h,al
	mov al,[irqm1]
	out 021h,al
@@:
	ret
	align 4
ResetIntVectors endp

if ?SETINT09
resetint09:
	xor ecx,ecx
	xchg cx,word ptr [oint09+4]
	jecxz @F
	mov edx,dword ptr [oint09+0]
	mov bl,9
	mov ax,205h
	int 31h
@@:
	ret
	align 4
endif

if ?NTSUPP

;--- for NT, access to VDD ideckvdd.dll is required

RunBop proc stdcall dwFunc:dword

local	dfBop:fword

	push ds
	push es
	push eax
	push ecx
	mov eax, dwFunc
	mov ecx, eax
	shl eax, 2
	add eax, ecx
	mov ecx, dwBopSel
	mov dword ptr [dfBop+0],eax
	mov word ptr [dfBop+4],cx
	jnz @F
	mov es,ecx
	mov ds,ecx
@@:
	pop ecx
	pop eax
	call fword ptr [dfBop]
	pop es
	pop ds
	ret
	align 4
runcxx label dword
;--- RegisterModule
	db 0C4h, 0C4h, 58h, 0
	retf
;--- UnRegisterModule
	db 0C4h, 0C4h, 58h, 1
	retf
;--- DispatchCall
	db 0C4h, 0C4h, 58h, 2
	retf

RunBop endp

svdd1	db "IDECKVDD.DLL",0
svdd2	db "Dispatch",0
svdd3	db "Init",0

loadvdd proc

	mov cx,1
	xor eax,eax
	int 31h
	jc error
	push ebx
	mov ebx, eax
	mov dwBopSel, eax

	mov ecx, offset runcxx
	push ecx
	pop dx
	pop cx
	mov ax,7
	int 31h
	mov cx,0
	mov dx,-1
	mov ax,8
	int 31h
	mov eax, cs
	lar ecx, eax
	shr ecx, 8
	mov ax,9
	int 31h
	pop ebx
	mov esi, offset svdd1 - offset runcxx
	mov ebx, offset svdd2 - offset runcxx
	mov edi, offset svdd3 - offset runcxx
	invoke RunBop, 0
error:
	ret
	align 4
loadvdd endp

endif

_GetTimeDiff proc stdcall uses ebx esi edi pDif:dword,pEnd:dword,pSta:dword

	push 0
	push 60
	push 60
	push 100

	mov edi,pDif
	mov esi,pEnd
	mov ebx,pSta
	mov ecx,4
	clc
sm1:
	pop edx
	mov al,[esi+3]
	sbb al,[ebx+3]
	jnc sm2
	add al,dl
	stc
sm2:
	mov [edi+3],al
	dec edi
	dec esi
	dec ebx
	loop sm1

	ret
	align 4
_GetTimeDiff endp

;*** MAIN proc ***

main proc c

	mov [flatsel],ds

	call getparam
	jc main_ex

	mov ah,03				;do a video BIOS call to make XP display
	mov bh,0				;our direct console output.
	int 10h

	mov ax,3306h
	int 21h
	.if (bx == 3205h)		;NT, 2k, XP?
		mov bOS, OS_NT
	.else
		mov ax,1600h
		int 2fh
		and al,7Fh
		.if (al)			;win9x/3x VMM?
			mov bOS, OS_W9X
		.endif
		mov ah,30h
		int 21h
		.if (al >= 20)		;os2?
			mov bOS, OS_OS2
		.endif
	.endif
	cmp [bMode], FM_I13	;allow Int 13h access
	jz @F
	.if bOS != OS_DOS
		invoke printf, CStr(lf,"direct disk access not allowed with this OS - aborted.",lf)
		jmp main_ex
	.endif
@@:
	.if bOS == OS_NT
if ?NTSUPP
		call loadvdd
		.if (CARRY?)
			invoke printf, CStr(lf,"can't load IDECKVDD.DLL - aborted.",lf)
			jmp main_ex
		.endif
		mov [hVDD], eax
else
		invoke printf, CStr(lf,"can't run on NT platform - aborted.",lf)
		jmp main_ex
endif
	.endif

if ?SETINDOS
	push es
	mov ah,34h
	int 21h 							; ES:[EBX] InDos-Flag
	mov dword ptr [InDOS+0],ebx
	mov word ptr [InDOS+4],es
	pop es
endif

;--- alloc the 128 kB sector buffer in DOS memory to ensure linear=physical

	mov bx,2001h
	mov ax,0100h
	int 31h
	jnc @F
	invoke printf, CStr(lf,"cannot allocate 128 kB buffer",lf,lf)
	jmp main_ex
@@:
	movzx eax, ax
	shl eax, 4
	mov [dwDMAList], eax
	add eax, 10h
	mov [bufadr],eax
	add eax,10000h-1		;begin on a 64 kb boundary for DMA
	xor ax, ax
	mov [bufadr2],eax

	mov eax, [bufadr]
	shr eax, 4
	shl eax, 16
	mov ax,1000h
	mov rmStack,eax		; use a 4 kB stack for PCI BIOS calls

	call setctl			; disable ctrl-c check
	call getint13parms
	jc main_ex

;--- clear the read buffer

	mov edi, [bufadr]
	mov ecx, 20000h/4
	cmp [bMode], FM_PIO
	jz @F
	mov ecx, 10000h/4
	mov edi, [bufadr2]
@@:
	mov eax, ecx
	shr eax, 8
	cmp fNoScan, 0
	jnz @F
	push ecx
	invoke printf, CStr(lf,"%u kB read buffer at linear address %X",lf), eax, [bufadr2]
	pop ecx
@@:
if 0  ; for debugging
	mov eax, 055AA55AAh
else
	xor eax,eax
endif
	rep stosd

	call parprot 		; parameter protocol
	jc main_ex1

	cmp fNoScan, 0
	jnz main_ex1

	mov ah, 2Ch			; get time
	int 21h
	mov ebx, offset timesta
	xchg ch,cl
	mov [ebx+0], cx
	xchg dh,dl
	mov [ebx+2], dx
	invoke writetimestamp, CStr("start: %u:%02u:%02u,%02u",lf)

	call checkhd
	call ResetIntVectors

	mov ah,2Ch			; get time
	int 21h
	mov ebx,offset timeend
	xchg ch,cl
	mov [ebx+0],cx
	xchg dh,dl
	mov [ebx+2],dx
	invoke writetimestamp, CStr(lf,"end: %u:%02u:%02u,%02u",lf)

	invoke _GetTimeDiff,addr timedif,addr timeend,addr timesta
	mov cx,word ptr [timedif+0]
	mov dx,word ptr [timedif+2]
	invoke writetimestamp, CStr("time: %u:%02u:%02u,%02u for ")
	mov eax,[sectors]
	invoke printf, CStr("%u sectors -",3Eh," "), eax

	mov esi,offset timedif
	lodsb
	movzx eax,al
	mov ecx,3600	;convert hours -> seconds
	mul ecx
	mov ebx,eax
	lodsb
	mov cl,60
	mul cl			;minutes -> seconds
	movzx eax,ax
	add ebx,eax
	lodsb			;seconds
	movzx eax,al
	add ebx,eax
	lodsb			;hsec
	movzx eax,al
	xchg ebx,eax
	mov ecx,100
	mul ecx
	add ebx,eax 	;ebx=hsec

	xor edx,edx
	mov eax,[sectors]
	mov ecx,512
	mul ecx 		;-> bytes read in eax
	and ebx,ebx
	jz @F
	div ebx 		;/ hsec -> read speed Bytes/hsec
@@:
	mov ecx,100
	mul ecx 		;bytes/sec in eax
	shr eax,10		;kbytes/sec

	invoke printf, CStr("%u kB/sec",lf), eax

	test [bFlags], FL_RES
	jz @F
	invoke printf, CStr(lf,"press Ctrl-Alt-Del to reboot!")
if ?SETINT09
	call resetint09
endif
	sti
	jmp $
@@:
main_ex1:
main_ex:
	test [bFlags], FL_UDMASET
	jz @F
	mov cl,[configb+88*2+1]
	movzx ecx,cl
	bsr eax,ecx
	jz @F                   ;jump if no UDMA mode supported
	mov [udmamode],al
	call setudmamode
@@:
	call ResetIntVectors	;reset 08, 13, HDIRQ
if ?SETINT09
	call resetint09
endif
if ?NTSUPP
	push eax
	mov eax,hVDD
	.if (eax != -1)
		invoke RunBop, 1	;UnregisterModule
	.endif
	pop eax
endif
	movzx eax,al
	ret
	align 4
main endp

mainCRTStartup proc c public
	call main
	mov ax,4c00h
	int 21h
mainCRTStartup endp

	end mainCRTStartup

