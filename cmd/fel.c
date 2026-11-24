// SPDX-License-Identifier: GPL-2.0+
/*
 * 'fel' command: ask the SPL to drop back into the BROM FEL routine
 * on the next boot, then reset the board.
 */
#include <command.h>
#include <cpu_func.h>
#include <linux/io.h>

/* Must match the magic checked by save_boot_params() in mach-sunxi/board.c */
#define FEL_MAGIC_ADDR	0x5ffffffc
#define FEL_MAGIC_VAL	0x46454c42	/* "FELB" */

static int do_fel(struct cmd_tbl *cmdtp, int flag, int argc, char *argv[])
{
	printf("## resetting into BROM FEL ...\n");

	writel(FEL_MAGIC_VAL, FEL_MAGIC_ADDR);

	reset_cpu();

	return 0;
}

U_BOOT_CMD(fel, 1, 0, do_fel,
	   "reboot into Allwinner BROM FEL mode",
	   ""
);
