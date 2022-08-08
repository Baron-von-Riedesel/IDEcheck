
;--- IDECKVDD is a NTVDM VDD
;--- needs JWasm/Masm v6 and HXDEV include files

	.386
	.MODEL FLAT, stdcall
	option casemap:none
	option proc:private

	.nolist
	include winbase.inc
	include winioctl.inc
	include vddsvc.inc
	include winuser.inc
	.cref
	.list

DAP struct
bSize		db ?	;size of structure
bRes		db ?	;reserved
wNumSec		dw ?	;sectors to transfer
dwBuffer	dd ?	;transfer buffer SSSS:OOOO
dwStartLow	dd ?	;start sector low
dwStartHigh	dd ?	;start sector high
;--- for EDD 3.0, there comes a 64bit flat transfer buffer address
DAP ends

EDD	struct
wSize	dw ?	;+0
wFlags	dw ?	;+2
dwCyl	dd ?	;+4
dwHeads	dd ?	;+8
dwSecs	dd ?	;+12
qwNumSecs dq ?	;+16
wSecSiz	dw ?	;+24
EDD	ends

;*** DPMI real-mode call structure

RMCS struct
union
rEDI	dd ?			;+0
rDI		dw ?
ends
union
rESI	dd ?			;+4
rSI		dw ?
ends
union
rEBP	dd ?			;+8
rBP		dw ?
ends
RESERVE dd ?			;+12
union
rEBX	dd ?			;+16
rBX 	dw ?
ends
union
rEDX	dd ?			;+20
rDX 	dw ?
ends
union
rECX	dd ?			;+24
rCX		dw ?
ends
union
rEAX	dd ?			;+28
rAX		dw ?
ends
rFlags	dw ?			;+32
rES 	dw ?			;+34
rDS 	dw ?			;+36
rFS 	dw ?			;+38	
rGS 	dw ?			;+40  
union
rCSIP	dd ?			;+42
struct
rIP 	dw ?
rCS 	dw ?
ends
ends
union
rSSSP	dd ?			;+46
struct
rSP 	dw ?
rSS 	dw ?
ends
ends
RMCS ends

;--- CStr() define a string in .CONST

CStr macro string:req
local sym,xxx
	.const
sym db string,0
	.code
	exitm <offset sym>
endm

@DbgOutC macro xx
ifdef _DEBUG
	invoke OutputDebugString, CStr(<xx>)
endif
endm

@DbgOut macro xx:REQ, parms:VARARG
ifdef _DEBUG
	pushad
	invoke wsprintf, addr szText, CStr(<xx>), parms
	invoke OutputDebugString, addr szText
	popad
endif
endm

	.data

	.data?

ifdef _DEBUG
szText	db 128 dup (?)
endif

	.code

;--- Init

Init proc public

	@DbgOutC <"IDECKVDD.Init",13,10>
	ret
	align 4
Init endp

;--- ES:EDI=RMCS

accessdrive proc

local	bFunc:dword
local	hDisk:dword
local	dwRead:dword
local	dwBuffer:dword
local	szDrv[32]:byte
local	ddi:DISK_DETECTION_INFO	;56
local	dpi:DISK_PARTITION_INFO	;24
local	DiskSize:QWORD		;8
local	dgx:DISK_GEOMETRY	;24

	invoke getEDI
	mov edi,eax
	invoke getES
	invoke VdmMapFlat, eax, edi, 1
	mov edi, eax

	mov eax,[edi].RMCS.rEDX
	movzx eax,al
	sub al,80h
	invoke wsprintf, addr szDrv, CStr("\\.\PhysicalDrive%u"), eax

	movzx ecx,word ptr [edi].RMCS.rSI
	movzx eax,word ptr [edi].RMCS.rDS
	shl eax,4
	add eax, ecx
	mov ebx, eax	;DS:SI=DAP

	mov eax, [edi].RMCS.rEAX
	movzx eax,ah
	mov bFunc, eax

	@DbgOut <"accessdrive, func=%X, DAP=%X",13,10>, bFunc, ebx

	xor ecx, ecx
	mov eax, bFunc
	and al,0Fh
	.if ((eax == 2) || (eax == 3))
		movzx ecx,word ptr [ebx].DAP.dwBuffer+0
		movzx eax,word ptr [ebx].DAP.dwBuffer+2
		shl eax,4
		add eax, ecx
		mov dwBuffer, eax
		mov ecx, GENERIC_READ
		.if (eax == 3)
			or ecx, GENERIC_WRITE
		.endif
	.endif
	invoke CreateFileA, addr szDrv, ecx, FILE_SHARE_READ or FILE_SHARE_WRITE,\
		0, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0
	cmp eax,-1
	jz openerror
	mov hDisk, eax
	mov eax, bFunc
	and eax,0Fh
	.if (eax == 8)
		invoke DeviceIoControl, hDisk, IOCTL_DISK_GET_DRIVE_GEOMETRY_EX, NULL,\
			0, addr dgx, 112, addr dwRead, 0
		.if (eax)
			@DbgOut <"accessdrive, DDI type=%X",13,10>, ddi.DetectionType
			push eax
			mov eax,dword ptr dgx.Cylinders
			mov ecx,dgx.TracksPerCylinder
			mov edx,dgx.SectorsPerTrack
			mov [ebx].EDD.dwCyl, eax
			mov [ebx].EDD.dwHeads, ecx
			mov [ebx].EDD.dwSecs, edx
			mov eax,dword ptr DiskSize+0
			mov edx,dword ptr DiskSize+4
			mov ecx, dgx.BytesPerSector
			mov [ebx].EDD.wSecSiz, cx
			div ecx
			mov [ebx].EDD.wSize, sizeof EDD
			mov [ebx].EDD.wFlags, 0
			mov dword ptr [ebx].EDD.qwNumSecs+0, eax
			mov dword ptr [ebx].EDD.qwNumSecs+4, edx
			pop eax
		.endif
	.else
		mov eax, [ebx].DAP.dwStartLow
		mov edx,512
		mul edx
		push edx
		mov edx, esp
		invoke SetFilePointer, hDisk, eax, edx, 0
		pop edx
		movzx ecx,[ebx].DAP.wNumSec
		shl ecx,9
		.if (bFunc == 43h)
;			invoke WriteFile, hDisk, dwBuffer, ecx, addr dwRead, 0
		.else
			invoke ReadFile, hDisk, dwBuffer, ecx, addr dwRead, 0
		.endif
	.endif
	push eax
	invoke CloseHandle, hDisk
	pop eax
	and eax, eax
	jz accerror
	mov [edi].RMCS.rFlags,0
	mov byte ptr [edi].RMCS.rEAX+1,0
	ret
accerror:
openerror:
	mov byte ptr [edi].RMCS.rEAX+1,2
	mov [edi].RMCS.rFlags,1
	ret
	align 4

accessdrive endp

;--- Dispatch
;--- function in bx
;--- bx=13: int 13h access

Dispatch proc public uses ebx edi

local	mbi:MEMORY_BASIC_INFORMATION

	@DbgOutC <"Dispatch enter",13,10>
	invoke getEBX
	movzx eax,al
	.if (eax == 13h)
		invoke setCF, 0
		invoke accessdrive
	.else
		@DbgOut <"unknown function CH=%X",13,10>, eax
		invoke setCF,1
	.endif
	@DbgOutC <"Dispatch exit",13,10>
	ret
	align 4
Dispatch endp

;*** main proc ***

DllMain proc public hInstance:dword, reason:dword, lpReserved:dword

	mov eax, reason
	.if (eax == DLL_PROCESS_ATTACH)
		@DbgOutC <"process attach",13,10>
		mov eax,1
	.elseif (eax == DLL_PROCESS_DETACH)
		@DbgOutC <"process detach",13,10>
	.elseif (eax == DLL_THREAD_ATTACH)
		@DbgOutC <"thread attach",13,10>
	.elseif (eax == DLL_THREAD_DETACH)
		@DbgOutC <"thread detach",13,10>
	.endif
	ret
	align 4
DllMain endp

	END DllMain

