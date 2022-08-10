@echo off
rem build with Masm/link

ml -nologo -coff -c -FlRelease\idecheck.lst -FoRelease\idecheck.obj -Sg idecheck.asm
link /nologo release\idecheck.obj /OUT:release\idecheck.EXE /MAP:release\idecheck.map /SUBSYSTEM:CONSOLE /FIXED:NO /STUB:\hx\Bin\LOADPEX.BIN
ml -nologo -coff -c -FlRelease\ideckvdd.lst -FoRelease\ideckvdd.obj -Sg -I\hx\include ideckvdd.asm
link /nologo release\ideckvdd.obj /OUT:release\ideckvdd.DLL /MAP:release\ideckvdd.map /SUBSYSTEM:CONSOLE /DEF:IDECKVDD.DEF /LIBPATH:\hx\Lib dkrnl32.lib duser32.lib ntvdm.lib

