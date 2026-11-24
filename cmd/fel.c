// SPDX-License-Identifier: GPL-2.0+
/*
 * Command to jump back into the Allwinner BROM FEL routine.
 */
#include <command.h>
#include <asm/arch/sys_proto.h>
#include <asm/system.h>

static int do_fel(struct cmd_tbl *cmdtp, int flag, int argc, char *argv[])
{
	extern unsigned long fel_stash[];

	printf("## jumping back to BROM FEL ...\n");

	return_to_fel(0x20, fel_stash[0]);

	return 0;
}

U_BOOT_CMD(fel, 1, 0, do_fel,
	   "reboot into Allwinner BROM FEL mode",
	   ""
);
