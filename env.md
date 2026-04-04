# Work Environment Description

The work space of this project is /home/jian/Download/splash.
- When building u-boot or linux, I prefer out-of-tree build in subdirectories inside ~/Downloads which is mounted with tmpfs.
- Cross-Compilation: This is a embedded software project. Please source /home/jian/.scripts/setup-oe.sh, it will setup the bash environment for cross compiling.
- Target Board: The target board is a embedded linux box named raft-gw-argon-vb, use can use this name to find the defconfig for both u-boot and linux.
- Hardware Access: The target's serial console is connected to /dev/ttyUSB0 with baudrate 115200. And its ethernet is connected to dhcp server and usually can get ip address 192.168.13.21. You can access the target using root as username and " " (a single space) as password.
- Please make build directory in ~/Download, b-linux for linux and b-boot for u-boot, and use rmake function provided in ~/.scripts/setup-oe.sh to do out-of-tree build.
- to update the kernel, you just need to scp the zImage to /mnt directory in the device and reboot the system.
