
;--- idecheck 
;--- reads HDs on with Int13, PIO and DMA access method
;--- assemble with JWasm/Masm v6

	.386
	.MODEL FLAT
	option casemap:none
	option proc:private

?SETINT08 equ 1	;grab timer IRQ
?SETINT09 equ 1	;grab keyboard IRQ
?SETINT13 equ 1	;grab int 13h (protected-mode only)
?SETHDIRQ equ 0	;grab HD IRQ (problem with native controllers!)
?NTSUPP   equ 1 ;support running on NT (use IDECKVDD.DLL)
?BIOSHD   equ 0 ;1=rely on 0040:0075 to contain # of HDs

@flat	equ <ds>
cr		equ 13
lf		equ 10
fIRQ	equ 48Eh	;address of "IRQ happened" flag

;--- externals

;wvsprintfA	proto stdcall :dword, :dword, :dword
;wsprintfA	proto c :dword, :dword, :VARARG

;--- macros

CStr macro string:vararg
local sym
	.const
sym	db string,0
    .code
	exitm <offset sym>
	endm

@putchr macro char
	ifnb <char>
	 mov al,char
	endif
	push eax
	call VioPutCharDir
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
szBus	db 4 dup (?)	;+24
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

	.CONST

;*** constants

dAbout db 'IDECHECK 1.53 (C) 1995-2021 Japheth',cr,lf
	db 'usage: IDECHECK drive [ options ]',cr,lf
	db cr,lf
	db ' drive: HD number, starts with 0',cr,lf
	db ' options:',cr,lf
	db '  /S:n - read n sectors/command (default 127, max. 256/128/128 for PIO/DMA/I13)',cr,lf
	db '  /M:n - set multiple sector (PIO only, default is current value)',cr,lf
	db "  /B:n - start read at sector n",cr,lf
	db '  /L:n - stop after n sectors',cr,lf
	db '  /U:n - set UDMA mode (DMA only)',cr,lf
	db '  /I13 - use Int 13h (default)',cr,lf
	db '  /PIO - use PIO',cr,lf
	db '  /DMA - use DMA (requires PCI 2.0c BIOS and Busmaster DMA controller)',cr,lf
	db '  /CHS - prefer CHS if LBA is available',cr,lf
	db '  /IGN - continue on errors',cr,lf
	db '  /16  - use 16bit INSW to read, not 32bit INSD (PIO only)',cr,lf
	db "  /NOI - use polling, not IRQ (PIO/DMA only, /I:n ignored)",cr,lf
	db "  /SGL - do not use multiple read (PIO only, /M:n ignored)",cr,lf
	db "  /REP - always read the same block (stop with ESC)",cr,lf
	db "  /RES - reboots machine after program termination",cr,lf
	db "  /LF  - print LF after CR",cr,lf
	db "  /P:n - set base port of IDE-controller (PIO/DMA only, defaults 1F0/170)",cr,lf
	db "  /I:n - set irq-line of IDE-controller (PIO/DMA only, defaults 14/15)",cr,lf
	db "  /D:vvvvdddd - set PCI vendor/device of Busmaster IDE controller to search for",cr,lf
	db "  ESC will stop HD checking",cr,lf
	db cr,lf
	db "IDECHECK should be run in true DOS for reliable results.",cr,lf
	db "Additionally, no disk-cache programs should be loaded.",cr,lf
	db '$'

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

	.DATA

FL_REP		equ 01h	;/REP set
FL_CHS		equ 02h	;/CHS set - use CHS mode
FL_RES		equ 04h	;/RES set - reboot after program termination
FL_DMA		equ 08h	;/DMA set
FL_I13		equ 10h	;/I13 set
FL_PIO		equ 20h	;/PIO set
FL_UDMASET	equ 40h	;UDMA mode has been modified (temporarily)

flags	dd FL_I13	;disk access method + flags
flatsel dd 0		;flat DATA selector

bDrive	db -1		;drive number parameter 0,1,2,...
drvmask db 0		;PIO/DMA: 0 for master, 10h for slave

stacyl	dw 0000h	;for CHS
stahead db 00		;for CHS
stasec	db 01		;for CHS

	align 4

maxdrv	dd 0
maxcyl	dd -1		;max value for C in C/H/S
maxhead dd -1		;max value for H in C/H/S
maxsec	dd -1		;max value for S in C/H/S

dwDMAList dd 0		;linear address DMA list (must be in DOS mem)

reqsecs dd 0		;/L:xxx value
bufadr	dd 0		;DOS memory buffer (128 kB)
bufadr2	dd 0		;64 kB buffer, aligned at 64 kB boundary
dwPath	  dd -1
dwClass   dd -1
wPrimary  dw 1F0h
wSecondary dw 170h
dwIDEport dd -1		;IDE port
dwDMAPort dd -1
dwVendor  dd -1		;vendor/device ID for IDE busmaster controller
if ?NTSUPP
hVDD	dd -1
dwBopSel dd 0
endif

numsec	dd 127	;numbers of sectors to read in one call
chssecs dd 0	;number of sectors in CHS mode
lbasecs dq 0	;number of sectors in LBA mode
cursec	dd 0	;current sector number
maxsecs dd 0	;# of sectors ( either CHS or LBA )
sectors dd 0	;sectors read so far
rmStack dd 0	;real mode stack SSSS:0000 address

InDOS	df 0	;indos flag address
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

fCont	db 0		;continue on errors?
fLBA	db 0		;use LBA?
fDMA	db 0		;DMA is ok
fMult	db 1		;use multi-sector reads (PIO)
fLF 	db 0		;print LF after error display?
fUseIRQ db 1		;/NOI switch
f32 	db 1		;prefer to use INSD for PIO
fMSaved db 0		;PIC status saved flag
multsec db 1		;no of sectors to read for multiple sector read
reqmult db 0		;/M:xx value
oldmult db 0		;saved previous value for multiple sector
last1x1 db 0		;value IDE port x+1
last1x7 db 0		;value IDE port x+7
irqno	db -1		;IRQ for HD
irqm1	db 0		;saved value of MPIC
irqm2	db 0		;saved value of SPIC
seccnt	db 0		;sector count value
udmamode db -1		;ultra DMA mode to use
bInt13Ext db 0		;int 13h extension version returned by ah=41h
fStop	db 0		;stop request (ESC pressed)
bOS		db 0		;0=DOS,1=NT,2=Win9x,3=OS2

	.DATA?

configb db 200h dup (?)	;buffer for configuration sector (PIO/DMA)

timesta db 4 dup (?)	;time in format hh:mm:ss:hs
timeend db 4 dup (?)	;time in format hh:mm:ss:hs
timedif db 4 dup (?)	;time in format hh:mm:ss:hs
ideregs db 5 dup (?)

	.CODE

	include vioout.inc

;--- printf, preserves all registers

if 0
printf proc c pszFormat:ptr byte, args:VARARG

local	szText[256]:byte

	pushad
	invoke wvsprintfA, addr szText, pszFormat, addr args
	lea esi, szText
nextitem:
	lodsb
	and al,al
	jz done
	cmp al,lf
	jnz @F
	@putchr cr
	mov al,lf
@@:
	@putchr
	jmp nextitem
done:
	popad
	ret
	align 4
printf endp
else
	include printf.inc
endif

_hexout proc
	push eax
	shr al,4
	call _nibout
	pop eax
_nibout::
	and al,0FH
	cmp al,10
	sbb al,69H
	das
	@putchr
	ret
	align 4
_hexout endp

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
	cmp ax,":d"
	jz o_d
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
	or byte ptr flags,FL_CHS
	ret
o_ign:
	or byte ptr fCont,1
	ret
o_sgl:
	mov byte ptr fMult,0
	ret
o_16:
	mov byte ptr f32,0
	ret
o_lf:
	mov byte ptr fLF,1
	ret
o_noi:
	mov byte ptr fUseIRQ,0
	ret
o_dma:
	and byte ptr [flags],not (FL_I13 or FL_PIO or FL_DMA)
	or byte ptr [flags],FL_DMA
	ret
o_i13:
	and byte ptr [flags],not (FL_I13 or FL_PIO or FL_DMA)
	or byte ptr [flags],FL_I13
	ret
o_pio:
	and byte ptr [flags],not (FL_I13 or FL_PIO or FL_DMA)
	or byte ptr [flags],FL_PIO
	ret
o_rep:
	or byte ptr [flags],FL_REP
	ret
o_res:
	or byte ptr [flags],FL_RES
	ret
o_b:						;/B:xx option
	inc ebx
	inc ebx
	invoke _getdec,ebx
	jc getoption_er
	and eax,eax
	jz getoption_er
	mov [cursec],eax
	ret
o_d:						;/D:xx option
	inc ebx
	inc ebx
	invoke _gethex,ebx
	jc getoption_er
	mov [dwVendor],eax
	clc
	ret
o_i:						;/I:xx option
	inc ebx
	inc ebx
	invoke _getdec,ebx
	jc getoption_er
	cmp eax,10h
	jnb getoption_er
	mov [irqno],al
	clc
	ret
o_l:						;/L:xx option
	inc ebx
	inc ebx
	invoke _getdec,ebx
	jc getoption_er
	and eax,eax
	jz getoption_er
	mov [reqsecs],eax
	ret
o_m:						;/M:xx option
	inc ebx
	inc ebx
	invoke _getdec,ebx
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
	invoke _gethex,ebx
	jc getoption_er
	mov [dwIDEport],eax
	ret
o_s:						;/S:xx option
	inc ebx
	inc ebx
	invoke _getdec,ebx
	jc getoption_er
	mov [numsec],eax
	ret
o_u:						;/U:xx option
	inc ebx
	inc ebx
	invoke _getdec,ebx
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

	mov dwErr,offset dAbout

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
	test [flags],FL_PIO	;for PIO, 256 sectors are allowed
	jnz @F
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
	mov edx, dwErr
	mov ah,9
	int 21h
	stc
	ret
	align 4
getparam endp

;--- set multi sector (for PIO)

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
	test byte ptr [fUseIRQ],1
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
	test byte ptr [fUseIRQ],1
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
	test byte ptr [fUseIRQ],1
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
	invoke printf, CStr("checked: multiple sector value seems to be %u",lf),eax
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
	mov ax,[ebx+2*59]
	test ah,1
	jz setmult_0
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
endif
setmult_1:
	mov al,[reqmult]
	call setmult1
	jc setmult_ex
	mov al,[reqmult]
	mov [multsec],al
	mov byte ptr fMult,1
	movzx eax,al
	invoke printf, CStr("multiple sectors set to %u",lf),eax
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
	call int13	;will be read into 128k buffer
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
	mov bl,8
	mov ax,204h
	int 31h
	mov dword ptr [oint08+0],edx
	mov word ptr [oint08+4],cx
	mov ecx,cs
	mov edx,offset i08rou
	mov ax,205h
	int 31h
endif
if ?SETINT09
	mov bl,9
	mov ax,204h
	int 31h
	mov dword ptr [oint09+0],edx
	mov word ptr [oint09+4],cx
	mov ecx,cs
	mov edx,offset i09rou
	mov ax,205h
	int 31h
endif
	test flags,FL_I13	;hook into in int 13h when reading DMA/PIO
	jnz done
if ?SETINT13
	mov bl,13h
	mov ax,204h
	int 31h
	mov dword ptr [oint13+0],edx
	mov word ptr [oint13+4],cx
	mov ecx,cs
	mov edx,offset i13rou
	mov ax,205h
	int 31h
endif
	in al,021h
	mov [irqm1],al
	in al,0A1h
	mov [irqm2],al
	or byte ptr [fMSaved],1
	mov al,0FFh
	out 0A1h,al
	mov al,0FCh
	out 021h,al

	test byte ptr [fUseIRQ],1
	jz done
if ?SETHDIRQ
	call getirq
	mov bl,al
	mov ax,204h
	int 31h
	mov dword ptr [ohdirq+0],edx
	mov word ptr [ohdirq+4],cx
	mov ecx,cs
	mov edx,offset irqrou
	mov ax,205h
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
	sub esp,34h
	mov [ebp-34h].RMCS.rEAX, eax
	mov [ebp-34h].RMCS.rEBX, ebx
	mov [ebp-34h].RMCS.rECX, ecx
	mov [ebp-34h].RMCS.rEDX, edx
	mov [ebp-34h].RMCS.rESI, esi
	mov [ebp-34h].RMCS.rEDI, edi
	mov eax, rmStack
	mov [ebp-34h].RMCS.rSSSP, eax
	mov [ebp-34h].RMCS.rFlags, 0
	mov edi, esp
	mov bx,001Ah
	mov cx,0
	mov ax,0300h
	int 31h
	mov edi,[ebp-34h].RMCS.rEDI
	mov esi,[ebp-34h].RMCS.rESI
	mov edx,[ebp-34h].RMCS.rEDX
	mov ecx,[ebp-34h].RMCS.rECX
	mov ebx,[ebp-34h].RMCS.rEBX
	mov ah,byte ptr [ebp-34h].RMCS.rFlags
	sahf
	mov eax,[ebp-34h].RMCS.rEAX
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

FindPath proc
	cmp [dwVendor],-1
	jz @F
	mov edx,[dwVendor]
	mov ecx,edx
	shr edx,16
	xor esi,esi
	mov ax,0B102h	;find device DX/CX
	call int1A
	jnc found2
	ret
@@:
	mov al,08Ah		;legacy, BM
	call getclass
	jnc found
	mov al,080h		;legacy, BM
	call getclass
	jnc found
	mov al,0FAh
	call getclass
	jnc found
	mov al,0F0h
	call getclass
	jnc found
	ret
found:
;	invoke	printf, CStr("PCI B103, ECX=%X : EBX=%X",lf), ecx, ebx
found2:
	movzx ebx,bx
	mov [dwPath],ebx
	ret
getclass:
	xor esi, esi	;device index in SI (0-n)
	mov ecx, 10100h	;class 01 (mass storage), subclass 01 (IDE)
	mov cl,al
	mov ax,0B103h	;find PCI class code
	push ecx
	call int1A
	pop ecx
	retn
	align 4
FindPath endp

displayahci proc uses ebx esi edi

	push 9
	call getpcireg ;get PCI 24 - AHCI Base Address
	jc exit
	mov esi, ecx
	invoke printf, CStr("AHCI Base Address=%X",lf), ecx
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
	mov ebx,[esi+0]
	invoke printf, CStr("HBA Caps (CAP): %X",lf), ebx
	xor eax,eax
	bt ebx,18
	setc al
	invoke printf, CStr("bit 18[SAM]=%u; 1=supports AHCI mode only",lf),eax
	mov ebx,[esi+4]
	invoke printf, CStr("Global HBA Control (GHC): %X",lf), ebx
	xor eax,eax
	bt ebx,31
	setc al
	invoke printf, CStr("bit 31[AE]=%u; 1=AHCI Enable",lf),eax

	invoke printf, CStr("Interrupt Status Register (IS): %X",lf), dword ptr [esi+8]
	invoke printf, CStr("Ports Implemented (PI): %X",lf), dword ptr [esi+12]
	invoke printf, CStr("AHCI Version (VS): %X",lf), dword ptr [esi+16]
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
displayahci endp

;--- get and display PCI infos

GetPCIInfo proc

	cmp [dwPath],-1
	jnz @F
	call FindPath
	jc exit
@@:
	cmp [dwPath],0	;invalid value returned by EDD BIOS?
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
	invoke printf, CStr("PCI %04X (%2u): command register=%X, status register=%X",lf), dwPath, edi, eax, ecx
	push 2
	call getpcireg ;get PCI 08-0B
	jc error
	movzx eax,cl
	shr ecx,8
	mov [dwClass],ecx ;contains 0B=BCC,0A=SCC,09=PI
	invoke printf, CStr("PCI %04X (%2u): revision ID=%X, class code=%X",lf), dwPath, edi, eax, ecx
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
			invoke printf, CStr("USB device, %02X (00=UHCI,10=OHCI,20=EHCI,30=XHCI",lf),eax
		.else
			invoke printf, CStr("PCI device's BCC (=Base Class Code) != 01 (mass storage device)",lf)
		.endif
		mov eax,dwClass
		.if eax == 010601h ;SATA AHCI
			call displayahci
		.endif
		jmp exit
	.endif
	test byte ptr [dwClass],80h	;busmaster?
	.if (ZERO?)
		invoke printf, CStr("IDE controller does NOT support Busmaster DMA!",lf)
		jmp exit
	.endif
	test byte ptr [dwClass],1	;legacy or native?
	jz @F
	push 4
	call getpcireg	;base port 0 (IDE primary base)
	jc error
	and cl,0FCh
	mov [wPrimary],cx
	invoke printf, CStr("PCI %04X (%2u): base address 0=%X ",lf), dwPath, edi, ecx
@@:
if 0
	push 5
	call getpcireg
	jc error
	invoke printf, CStr("PCI %04X (%2u): base address 1=%X",lf), dwPath, edi, ecx
endif
	test [dwClass],1	;native or legacy?
	jz @F
	push 6
	call getpcireg	;base port 2 (IDE secondary base)
	jc error
	and cl,0FCh
	mov [wSecondary],cx
	invoke printf, CStr("PCI %04X (%2u): base address 2=%X",lf), dwPath, edi, ecx
@@:
if 0
	push 7
	call getpcireg
	jc error
	and cl,0Fh
	invoke printf, CStr("PCI %04X (%2u): base address 3=%X",lf), dwPath, edi, ecx
endif
	push 8
	call getpcireg	;base DMA controller
	jc error
	and cl,0FCh
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

	test [dwClass],1	;legacy?
	jz @F
	push 15
	call getpciregb
	jc error
	movzx ecx, cl
	mov [irqno],cl
	invoke printf, CStr("PCI %04X (%2u): interrupt line (IRQ)=%X",lf), dwPath, edi, ecx
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

SetMaxValues proc
	mov ebx,offset configb
	movzx eax,word ptr [ebx+1*2]
	mov [maxcyl], eax
	movzx ecx,word ptr [ebx+3*2]
	mov [maxhead], ecx
	movzx edx,word ptr [ebx+6*2]
	mov [maxsec], edx
	invoke printf, CStr("CFG: cylinder/head/sector: %u/%u/%u - "), eax, ecx, edx

	mov eax,[maxsec]
	mov ecx,[maxhead]
	mul ecx
	mov ecx,[maxcyl]
	mul ecx
	mov [chssecs],eax
	invoke printf, CStr("%u sectors",lf),eax

	test [fLBA],1
	jz @F
	mov ebx,offset configb
	mov eax,[ebx+2*60]
	mov dword ptr [lbasecs+0],eax
	mov dword ptr [lbasecs+4],0
	invoke printf, CStr("CFG  60: LBA sectors: %u",lf),eax
@@:
	ret
	align 4
SetMaxValues endp

setmaxsecs proc
	mov eax,[reqsecs]	;sectors set with /L:xxx ?
	and eax,eax
	jnz done
	mov eax,dword ptr lbasecs
	cmp dword ptr lbasecs+4,0
	jz @F
	mov eax,-1
@@:
	test [fLBA],1
	jnz @F
	mov eax,[chssecs]
@@:
	sub eax,[cursec]	;do we start at sector 0 or is /B:xxx set?
	jnc done
	xor eax, eax
done:
	mov [maxsecs],eax
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
	or flags,FL_CHS
;	test cl,4
;	jnz int1348ok
noint1348:
	mov ah,08h
	call int13
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
	mov chssecs,eax
	mov dword ptr lbasecs,eax
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
	call int13
	jc error
	mov ebx, [bufadr]
	mov eax, dword ptr @flat:[ebx].EDD.qwNumSecs+0
	mov edx, dword ptr @flat:[ebx].EDD.qwNumSecs+4
	mov dword ptr lbasecs+0, eax
	mov dword ptr lbasecs+4, edx
	mov chssecs, eax
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
	mov eax,dword ptr @flat:[ebx].EDD30.szBus
	cmp eax," ICP"
	jnz noedd30
	mov eax,dword ptr @flat:[ebx].EDD30.szIFType+0
	mov ecx,dword ptr @flat:[ebx].EDD30.szIFType+4
	mov dword ptr [configb+0],eax
	mov dword ptr [configb+4],ecx
	invoke printf, CStr("EDD30: interface type: %s",lf), addr configb
	test [flags],FL_I13
	jnz @F
	cmp eax," ATA"	;for /DMA and /PIO, interface MUST be "ATA"
	jz @F
	cmp eax,"ATA"
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
	invoke printf, CStr("EDD: LBA sectors: %lu",lf), lbasecs
	mov eax, @flat:[ebx].EDD.dwCyl
	mov ecx, @flat:[ebx].EDD.dwHeads
	mov edx, @flat:[ebx].EDD.dwSecs
	invoke printf, CStr("EDD: cylinder/head/sector: %u/%u/%u",lf), eax, ecx, edx
done:
	mov [maxcyl],eax
	mov [maxhead],ecx
	mov [maxsec],edx
	test [flags],FL_I13
	jnz @F
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
	invoke printf, CStr("drive %u invalid",lf),eax
	stc
	ret
error2:
	movzx eax,[bDrive]
	invoke printf, CStr("drive %u isn't ATA",lf),eax
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

parprot proc stdcall

	call getint13parms
	jc exit

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
	jmp pcidone
nopci2:
	invoke printf, CStr("no PCI v2.0c BIOS found",lf)
pcidone:
	test flags, FL_DMA
	jz @F
	cmp [dwDMAPort],-1
	jnz @F
	invoke printf, CStr("no PCI Busmaster IDE controller found",lf)
	stc
	ret
@@:
	invoke printf, CStr("flushing cache ... ")
	mov ax,4A10h		   ;flush Cache
	mov bx,0001h
	int 2Fh
	invoke printf, addr szOk
	invoke printf, CStr("reading partition table ... ")
	call readpartition
	invoke printf, addr szOk

	call SetIntVectors

	test flags,FL_I13
	jnz exit

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
	invoke printf, CStr("seek cylinder 0 ... ")
	call setcyl0
	mov ecx, offset szOk
	jnc @F
	mov ecx, offset szFail
@@:
	invoke printf, ecx
	mov ebx,offset configb
	mov al,[ebx+2*49+1]
	test al,1
	setnz [fDMA]
	test al,2
	setnz [fLBA]
	invoke SetMaxValues
	movzx edx, word ptr [ebx+2*49]
	movzx ecx, [fDMA]
	movzx eax, [fLBA]
	invoke printf, CStr("CFG  49=%4X: DMA=%u, LBA=%u",lf), edx, ecx, eax

	test byte ptr [flags],FL_CHS
	jz @F
	mov byte ptr [fLBA],0
	invoke printf, CStr("CFG: LBA not used",lf)
@@:

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

;--- multiword DMA modes

	mov dx,[ebx+63*2]
	movzx edx,dx
	invoke printf, CStr("CFG  63=%4X: Multiword DMA modes supported:"),edx
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
	movzx edx,byte ptr [ebx+63*2+1]
	bsf eax,edx
	jz @F
	pushad
	invoke printf, CStr(", current %u"), eax
	popad
@@:
	invoke printf, CStr(lf)

;--- Advanced PIO modes

	movzx eax,word ptr [ebx+53*2]
	test al,2	;word at 64 valid?
	.if (ZERO?)
	   invoke printf, CStr("CFG  53=%4X: No Advanced PIO modes supported",lf),eax
	   jmp noapio
	.endif

	movzx ecx,word ptr [ebx+64*2]
	invoke printf, CStr("CFG  64=%4X: Advanced PIO modes supported:"),ecx
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

;--- UDMA modes

	movzx eax,word ptr [ebx+53*2]
	test al,4
	setnz cl
	movzx ecx,cl
	push ecx
	invoke printf, CStr("CFG  53=%4X: UDMA valid[bit 2]=%u",lf),eax,ecx
	pop ecx
	and ecx,ecx
	jz noudma

	test flags, FL_DMA
	jz noudmaset
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
	invoke printf, CStr("CFG  88=%4X: UDMA modes supported:"),ecx
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
	mov ecx, CStr(", current is %u", lf)
	movzx edx,byte ptr [ebx+88*2+1]
	bsf eax,edx
	jnz @F
	mov ecx, CStr(", current is none", lf)
@@:
	pushad
	invoke printf, ecx, eax
	popad
noudma:
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

	mov ebx,offset configb
	mov ax,[ebx+2*47]
	movzx eax,al
	invoke printf, CStr("CFG  47=%4X: max. multiple sector value is %u",lf), eax, eax

	test byte ptr [fMult],1
	jz parprot_4

	mov ebx,offset configb
	mov ax,[ebx+2*59]
	push eax
	movzx eax,al
	invoke printf, CStr("CFG  59=%4X: current multiple sector value: %u"),eax,eax
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
	mov byte ptr fMult,0
	cmp byte ptr [reqmult],0
	jnz parprot_2
	invoke printf, CStr("will not use multiple sector read (try /M switch)",lf)
parprot_2:
	cmp byte ptr [reqmult],0
	jz parprot_4
	call setmult
	jc parprot_ex
parprot_4:
	test byte ptr [f32],1
	jnz @F
	invoke printf, CStr("16-Bit IO (INSW) will be used",lf)
@@:
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
	call waitready
	jc error
	or [flags],FL_UDMASET
	clc
	ret
error:
	stc
	ret
	align 4
setudmamode endp

;*** ctrl-c abfangen ***

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

ir23 proc far
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

;--- protected-mode int 13h

i13rou proc far
	mov ah,80h
	stc
	retf 4
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
	sub ebx,[sectors]
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

prepregs proc c

	test byte ptr fLBA,1
	jnz prepregs_1
	test byte ptr [flags],FL_REP
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
	sub ebx,[sectors]
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
	mov AX,@flat:[BX]
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
	and ah,ah
checkifescpressed_ex:
	pop ebx
	ret
endif
	align 4
checkifescpressed endp

;*** read a hd until ESC is pressed or the end is reached

checkhd proc near

	test flags,FL_I13
	jnz @F
	push es
	les ebx,[InDOS]
	inc byte ptr es:[ebx]
	pop es
	call SaveDevStat		;does low-level IDE access
@@:
	mov dl,[stasec] 	;sector   => dl   CHS addressing only
	mov cx,[stacyl] 	;cylinder => ch
	mov dh,[stahead]	;head	  => dh
check_0:
	call checkifescpressed
	jnz done
	push ecx
	push edx
	call setALreg		;set number of sectors in AL
	call readcore
	pop edx
	pop ecx
	call protocol
	jnc @F
	test byte ptr fCont,1
	jz done
	mov [numsec],1
	inc [cursec]
@@:
	call prepregs
	jnc check_0
done:
	test flags,FL_I13
	jnz exit
	call resetmultsec		;multiple sector reset
	cli
	call RestoreDevStat
	push es
	les ebx,[InDOS]
	dec byte ptr es:[ebx]
	pop es
	sti
exit:
	ret
	align 4
checkhd endp

;--- call int 13h, AH=02, 42, 48 
;--- inp: EAX, ECX, EDX
;--- for read/writes, the DOS 128 kB buffer will be used

int13 proc
	push edi
	push ebx
	push ebp
	mov ebp,esp
	sub esp,34h
	mov [ebp-34h].RMCS.rAX, ax
	mov [ebp-34h].RMCS.rDX, dx
	mov [ebp-34h].RMCS.rSSSP, 0
	mov [ebp-34h].RMCS.rFlags, 0
	cmp ah,42h
	jz is42
	cmp ah,02h
	jz is02
	cmp ah,48h
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
	mov bx,0013h
	mov cx,0
if ?NTSUPP
	cmp hVDD,-1
	jnz handleNT
endif
	mov ax,0300h
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
int13 endp

;--- read drive using int 13h
;--- CHS: AL=num sectors, DH=head, DL=start sector, CX=cylinder 

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
	jmp int13
use42:
	mov ah,42h
	jmp int13
	align 4
readi13 endp

;*** readcore ***
;***
;*** for CHS: CX=cylinder, DH=Head, DL=Sector
;*** CHS + LBA: AL=secs
;*** out: NC -> EAX=sectors read
;***       C -> error

readcore proc near

	push ebp
	mov ebp,esp
	test flags, FL_I13
	jz noint13
	mov bh,al
	call readi13
	mov bl,0
	jnc readcore_3
	jmp readcore_ex
noint13:
	sub esp,4
	mov bh,dh
	dec al
	test flags, FL_DMA
	jz @F
	cmp al,80h
	jc @F
	mov al,7Fh			;max 127
@@:
	inc al
	mov bl,al

	mov [esp+0],al		;1x2 (sectors to read)

	test byte ptr fLBA,1	;use LBA address?
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
	test flags, FL_DMA
	jnz @F
	call waitready
	jc readcore_er3
@@:
	mov edi,[bufadr]   ;the buffer is zero-based flat!

	test byte ptr flags,FL_DMA
	jz @F
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
	test byte ptr fMult,1
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
	test byte ptr flags,FL_DMA
	jz polldata

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

	test byte ptr flags,FL_DMA
	jz nodma

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
	test byte ptr flags,FL_REP
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

protocol proc c

	pushad
	pushfd

	lahf
	test byte ptr [flags],FL_REP
	jnz protok_0
	test byte ptr [fLBA],1
	jnz protok_1
	call protoCHS
	jmp protok_2
protok_0:
	push eax
	mov eax,[sectors]
	invoke printf,CStr("%9u"), eax
	pop eax
	jmp protok_2
protok_1:
	push eax
	mov eax,[cursec]
	invoke printf,CStr("%9u"), eax
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
	@putchr lf
protok_4:
	@putchr cr
	popfd
	popad
	ret
	align 4
protocol endp

;*** display CHS protocol

protoCHS proc c

	push eax
	push edx
	push edx
	mov eax,ecx 	;cylinder
	invoke printf, CStr("%5u"), eax
	pop eax
	mov al,ah		;head
	movzx eax,al
	invoke printf, CStr("%5u"), eax
	pop eax
	movzx eax,al
	invoke printf, CStr("%4u"), eax
	pop eax
	ret
	align 4
protoCHS endp

;--- display error flags in AL
;--- modifies EBX

errorregout proc
	mov bl,al
	@putchr '['
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
	@putchr ']'
	ret
	align 4
errorregout endp

;--- modifies EAX, EBX

errorout proc near

	push eax
	@putchr ' '
	mov al,[seccnt]
	invoke _hexout
	@putchr ' '
	mov al,[last1x1]
	invoke _hexout
	mov al,[last1x1]
	call errorregout
	@putchr ' '
	mov al,[last1x7]
	invoke _hexout
	@putchr ' '
	pop eax
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
	test byte ptr [fMSaved],1
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

local	str1[80]:byte

	mov [flatsel],ds

	call getparam
	jc main_ex

	mov ah,03				;do a video BIOS call to make XP display
	mov bh,0				;our direct console output.
	int 10h

	mov ax,3306h
	int 21h
	.if (bx == 3205h)		;NT, 2k, XP?
		mov bOS, 1
	.else
		mov ax,1600h
		int 2fh
		and al,7Fh
		.if (al)			;win9x/3x VMM?
			mov bOS, 2
		.endif
		mov ah,30h
		int 21h
		.if (al >= 20)		;os2?
			mov bOS, 3
		.endif
	.endif
	test [flags],FL_I13	;allow Int 13h access
	jnz @F
	.if (bOS)
		invoke printf, CStr(lf,"direct disk access not allowed with this OS - aborted.",lf)
		jmp main_ex
	.endif
@@:
	.if (bOS == 1)
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
	.else
if ?BIOSHD
		movzx ecx,byte ptr @flat:[475h]
else
		mov ah,08h
		mov dl,80h
		int 13h
		jnc @F
		mov dl,0
@@:
		movzx ecx, dl
endif
		mov [maxdrv],ecx
		movzx eax,[bDrive]
		.if (eax >= ecx)
			invoke printf, CStr(lf,"drive %u is invalid ( [0040:0075]=%u )",lf), eax, ecx
			jmp main_ex
		.endif
	.endif

	push es
	mov ah,34h
	int 21h 							; ES:[EBX] InDos-Flag
	mov word ptr [InDOS+4],es
	mov dword ptr [InDOS+0],ebx
	pop es

;--- alloc the 128 kB sector buffer in DOS memory to ensure linear=physical

	mov bx,2001h
	mov ax,0100h
	int 31h
	jnc @F
	invoke printf, CStr(lf,"cannot allocate 128 kB buffer",lf,lf)
	jmp main_ex
@@:
	movzx eax,ax
	shl eax, 4
	mov [dwDMAList],eax
	add eax,10h
	mov [bufadr],eax
	mov edi, eax
	add eax,10000h-1		;begin on a 64 kb boundary for DMA	
	xor ax,ax
	mov [bufadr2],eax
	mov ecx,20000h/4
	test [flags],FL_PIO
	jnz @F
	mov ecx,10000h/4
	mov edi, eax
@@:
	mov eax,ecx
	shr eax,8
	invoke printf, CStr(lf,"%u kB read buffer at linear address %X",lf), eax, edi
	xor eax,eax
	rep stosd

	mov eax, [bufadr]
	shr eax, 4
	shl eax, 16
	mov ax,1000h
	mov rmStack,eax		;use a 4 kB stack for PCI BIOS calls

	call setctl			;disable ctrl-c check
	call parprot 		;parameter protocol
	jc main_ex1

	mov ah,2Ch			;get time
	int 21h
	mov ebx,offset timesta
	xchg ch,cl
	mov [ebx+0],cx
	xchg dh,dl
	mov [ebx+2],dx
	invoke writetimestamp, CStr("start: %u:%02u:%02u,%02u",lf,lf)

	mov ebx,offset regtxt1
	test byte ptr fLBA,1
	jnz @F
	test byte ptr flags,FL_REP
	jnz @F
	mov ebx,offset regtxt2
@@:
	invoke printf, CStr("%s"), ebx
	call checkhd
	call ResetIntVectors

	mov ah,2Ch			;get time
	int 21h
	mov ebx,offset timeend
	xchg ch,cl
	mov [ebx+0],cx
	xchg dh,dl
	mov [ebx+2],dx
	invoke writetimestamp, CStr(lf,lf,"end: %u:%02u:%02u,%02u",lf)

	invoke _GetTimeDiff,addr timedif,addr timeend,addr timesta
	mov cx,word ptr [timedif+0]
	mov dx,word ptr [timedif+2]
	invoke writetimestamp, CStr("time: %u:%02u:%02u,%02u for ")
	mov eax,[sectors]
	invoke printf, CStr("%u sectors -",3Eh," "),eax

	mov esi,offset timedif
	lodsb
	movzx eax,al
	mov ecx,3600	   ;convert hours -> seconds
	mul ecx
	mov ebx,eax
	lodsb
	mov cl,60
	mul cl			   ;minutes -> seconds
	movzx eax,ax
	add ebx,eax
	lodsb				   ;seconds
	movzx eax,al
	add ebx,eax
	lodsb				   ;hsec
	movzx eax,al
	xchg ebx,eax
	mov ecx,100
	mul ecx
	add ebx,eax 	   ;ebx=hsec

	xor edx,edx
	mov eax,[sectors]
	mov ecx,512
	mul ecx 		   ;-> bytes read in eax
	and ebx,ebx
	jz @F
	div ebx 		   ;/ hsec -> read speed Bytes/hsec
@@:
	mov ecx,100
	mul ecx 		   ;bytes/sec in eax
	shr eax,10		   ;kbytes/sec

	invoke printf, CStr("%u kB/sec",lf),eax

	test byte ptr [flags],FL_RES
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
	test [flags],FL_UDMASET
	jz @F
	mov cl,[configb+88*2+1]
	movzx ecx,cl
	bsr eax,ecx
	jz @F
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

