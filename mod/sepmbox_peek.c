// SPDX-License-Identifier: GPL-2.0
#include <linux/bitfield.h>
/*
 * sepmbox_peek - read-only diagnostic for the Apple SEP on t8112.
 *
 * v1 established: our GETRAND + BOOT_TZ0 are still queued in the AP->SEP FIFO
 * (A2I not EMPTY) and nothing ever came back (I2A EMPTY). The SEP never read
 * them, so it is not merely ignoring us.
 *
 * v2 asks why. Two candidates:
 *   - the ps_sep power domain is not actually active (despite apple,always-on)
 *   - the SEP's ASC CPU was never started
 *
 * The second is the live suspicion: rtkit-helper.c, aop.rs and pmp.rs all
 * start their coprocessor with CPU_CONTROL(0x44) |= RUN(BIT(4)), but sep.rs
 * never ioremaps its reg region at all, so it has no code that could.
 *
 * Reads only. Writes nothing.
 */
#include <linux/module.h>
#include <linux/io.h>

#define SEP_ASC_PHYS		0x25e400000ULL	/* sep node reg */
#define SEP_ASC_SIZE		0x6c000
#define SEP_MBOX_PHYS		0x25e408000ULL
#define SEP_MBOX_SIZE		0x4000
#define PMGR_PS_SEP_PHYS	0x23b700c00ULL	/* pmgr base + ps_sep reg 0xc00 */

#define ASC_CPU_CONTROL		0x44
#define ASC_CPU_CONTROL_RUN	BIT(4)

#define ASC_MBOX_A2I_CONTROL	0x110
#define ASC_MBOX_I2A_CONTROL	0x114
#define ASC_MBOX_CONTROL_FULL	BIT(16)
#define ASC_MBOX_CONTROL_EMPTY	BIT(17)

#define PMGR_RESET		BIT(31)
#define PMGR_DEV_DISABLE	BIT(10)
#define PMGR_PS_ACTUAL		GENMASK(7, 4)
#define PMGR_PS_TARGET		GENMASK(3, 0)
#define PMGR_PS_ACTIVE		0xf

static u32 peek(u64 phys, size_t size, u32 off, const char *what)
{
	void __iomem *base = ioremap(phys, size);
	u32 v;

	if (!base) {
		pr_err("sepmbox_peek: ioremap 0x%llx failed\n", phys);
		return 0;
	}
	v = readl_relaxed(base + off);
	iounmap(base);
	pr_info("sepmbox_peek:   %-22s = 0x%08x\n", what, v);
	return v;
}

static int __init sepmbox_peek_init(void)
{
	u32 a2i, i2a, cpu, ps;

	pr_info("sepmbox_peek: --- SEP state ---\n");

	ps = peek(PMGR_PS_SEP_PHYS, 4, 0, "pmgr ps_sep");
	pr_info("sepmbox_peek:     target=0x%lx actual=0x%lx%s%s\n",
		FIELD_GET(PMGR_PS_TARGET, ps), FIELD_GET(PMGR_PS_ACTUAL, ps),
		(ps & PMGR_RESET) ? " RESET" : "",
		(ps & PMGR_DEV_DISABLE) ? " DEV_DISABLE" : "");

	cpu = peek(SEP_ASC_PHYS, SEP_ASC_SIZE, ASC_CPU_CONTROL, "ASC CPU_CONTROL");
	pr_info("sepmbox_peek:     CPU RUN bit is %s\n",
		(cpu & ASC_CPU_CONTROL_RUN) ? "SET (cpu running)" : "CLEAR (cpu halted)");

	a2i = peek(SEP_MBOX_PHYS, SEP_MBOX_SIZE, ASC_MBOX_A2I_CONTROL, "A2I_CONTROL AP->SEP");
	i2a = peek(SEP_MBOX_PHYS, SEP_MBOX_SIZE, ASC_MBOX_I2A_CONTROL, "I2A_CONTROL SEP->AP");
	pr_info("sepmbox_peek:     A2I %s, I2A %s\n",
		(a2i & ASC_MBOX_CONTROL_EMPTY) ? "empty" : "HAS DATA (undrained)",
		(i2a & ASC_MBOX_CONTROL_EMPTY) ? "empty" : "HAS DATA (unread reply)");

	pr_info("sepmbox_peek: --- verdict ---\n");
	if ((ps & PMGR_RESET) || FIELD_GET(PMGR_PS_ACTUAL, ps) != PMGR_PS_ACTIVE)
		pr_info("sepmbox_peek: power domain is NOT active -> SEP block is off\n");
	else if (!(cpu & ASC_CPU_CONTROL_RUN))
		pr_info("sepmbox_peek: powered but CPU halted -> nobody ever started the SEP\n");
	else
		pr_info("sepmbox_peek: powered and running -> silence is a protocol problem\n");

	return -EAGAIN;	/* print and unload */
}

module_init(sepmbox_peek_init);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Read-only Apple SEP power/CPU/mailbox state");
