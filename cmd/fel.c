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
	unsigned long sp_brom = fel_stash[0];
	unsigned long lr_brom = 0x20;

	printf("## jumping back to BROM FEL ...\n");

	if (fel_stash[3] & CR_V)	/* SCTLR bit13: vectors at 0xffff0000 */
		lr_brom |= 0xffff0000;

	asm volatile(
		"mov	sp, %0\n"
		"mcr	p15, 0, %1, c12, c0, 0\n"	/* VBAR  */
		"mcr	p15, 0, %2, c1, c0, 0\n"	/* SCTLR */
		"msr	cpsr_f, %3\n"			/* CPSR  */
		"bx	%4\n"
		:
		: "r"(sp_brom), "r"(fel_stash[4]), "r"(fel_stash[3]),
		  "r"(fel_stash[2]), "r"(lr_brom)
		: "memory");

	return 0;
}

U_BOOT_CMD(fel, 1, 0, do_fel,
	   "reboot into Allwinner BROM FEL mode",
	   ""
);
