
 1. About

 IDECHECK measures speed of IDE hard disks. Unlike other such programs
 it may directly access the IDE controller, without using interrupt 13h.
 This is useful if the int 13h interface is unable to run the harddisk at
 full speed. IDECHECK just reads the hard disk until either all sectors 
 have been read or ESC has been pressed. For more details run IDECHECK -?.

 IDECHECK will detect what type of controller handles the disk. Low-level
 access is not possible if a SATA disk runs in AHCI-mode.

 2. Requirements

 To get reliable results IDECHECK must run in true DOS. It will work in
 a Windows DOS box with the /I13 access method. To run in Windows NT/XP,
 IDECKVDD.DLL is needed.
 
 IDECHECK is a 32-bit DPMI program; it's stubbed with HDPMI, that will be
 used if IDECHECK runs in true DOS.

 
 3. Usage

 To run IDECHECK, enter
 
 IDECHECK drive [ options ]
 
 <drive> is the number of the HD to test, 0 is the first
 <options> are:

  /I13 - use Interrupt 13h API (default)
  /PIO - access HD directly with PIO
  /DMA - access HD directly with DMA. This requires a PCI 2.0c BIOS and
         a PCI Busmaster DMA controller.
  
  /S:n - read n sectors per command. Default is 127; the maximum for
         Int 13h and DMA is 128, for PIO it's 256.
  /M:n - set multiple sector (PIO only, default is current value)
  /B:n - start read at sector n
  /L:n - stop after n sectors
  /U:n - set UDMA mode (DMA only)
  /CHS - prefer to use CHS if LBA is available
  /IGN - continue on errors
  /16  - use 16bit INSW to read, not 32bit INSD (PIO only)
  /NOI - use polling, not IRQ (PIO/DMA only, /I:n ignored)
  /SGL - do not use multiple read (PIO only, /M:n ignored)
  /REP - always read the same block (stop with ESC)
  /RES - reboots machine after program termination
  /LF  - print LF after CR
  /P:n - set base port of IDE-controller (PIO/DMA only, defaults 1F0/170)
  /I:n - set irq-line of IDE-controller (PIO/DMA only, defaults 14/15)
  /D:vvvvdddd - set PCI vendor/device of Busmaster IDE controller to
         search for (DMA only). Usually not needed on modern systems, since
         this information is returned by the Int 13h EDD BIOS.
 
 If options /PIO or /DMA are used, IDECHECK should not be run on a system
 with a disk-cache installed, because the cache program might get confused. 
 Also, when using these modes, no TSR should be installed which might access
 the HD in the background, since for security reasons IDECHECK will disable
 Int 13h temporarily.

 For disks larger than 128 GB IDECHECK may not be able to access the part
 beyond the 128 GB boundary, since it uses the 28-bit LBA addressing mode
 only.
 

 4. History
 
 __/2022, 1.55: int 08/09 no longer intercepted.
       check for busmaster enabled in PCI command register for /DMA.
 06/2022, 1.54: progress display reduced to a 3-4 times per second;
       drive valid check relies on int 13h, ah=41h/48h/08h only.
 01/2021, 1.53: default no of sectors to read changed to 127.
       display controller type and status more detailed.
 06/2012, 1.52: to make XP display direct writes to the console, a
       dummy video BIOS call was added.
 09/2008, 1.51: bugfix: display of read errors was wrong.
 05/2008, 1.50: binary now built with JWasm+WLink. Masm+MS Link optional.
 03/2008, 1.49: source code added to the package.
 03/2008, 1.48: stack size reduced from 1 MB to 4 kB.
 02/2008, 1.47: IDECHECKS "works" on NT platforms with the help of 
       IDECKVDD.DLL.
 02/2008, 1.46: binary format changed to DOS PE.
 12/2007, 1.45: test added to ensure that IDE controller supports Busmaster
       DMA if /DMA switch is active.
 12/2007, 1.44: check for max sectors set with /S improved.
 12/2007, 1.43: /I13 is now the default access method.
       /D option changed to set the vendor/device ID.
       some more error checks added.
 12/2007, 1.42: Non-ATA disks refused only for /PIO and /DMA, not for /I13.
       bugfix: reading with CHS set sector no 0.
 12/2007, 1.41: the binary is now stand-alone, no need for HDPMI32.EXE anymore.
       Non-ATA disks will be refused.
 12/2007, 1.40: "native" IDE controllers are supported as well.
 09/2006, 1.32: option /U:x added.


 5. License

 IDECHECK is distributed under the MIT license; see file license.txt for
 details.
 
