// SPDX-License-Identifier: GPL-2.0
/*
 * sepcpu_start - start the SEP's ASC CPU, if and only if it is halted.
 *
 * Background: apple_sep queued GETRAND + BOOT_TZ0 at boot and they are still
 * sitting undrained in the AP->SEP FIFO. The SEP is not refusing them, it is
 * not executing. sep.rs never ioremaps its reg region, so unlike every other
 * Apple coprocessor driver (rtkit-helper.c, aop.rs, pmp.rs) it never performs
 * the CPU_CONTROL |= RUN write that starts the processor.
 *
 * This module does exactly that write, then watches whether the SEP drains
 * the messages that have been waiting since boot. If the CPU is already
 * running, or the power domain is not active, it writes nothing and bails.
 *
 * If the SEP wakes up, apple_sep's own IRQ handler will log the reply as
 * "RX ep=..." lines -- check dmesg for those too.
 */
#include <linux/module.h>
#include <linux/bitfield.h>
#include <linux/delay.h>
#include <linux/io.h>

#define SEP_ASC_PHYS		0x25e400000ULL
#define SEP_ASC_SIZE		0x6c000
#define SEP_MBOX_PHYS		0x25e408000ULL
#define SEP_MBOX_SIZE		0x4000
#define PMGR_PS_SEP_PHYS	0x23b700c00ULL

#define ASC_CPU_CONTROL		0x44
#define ASC_CPU_CONTROL_RUN	BIT(4)

#define ASC_MBOX_A2I_CONTROL	0x110
#define ASC_MBOX_I2A_CONTROL	0x114
#define ASC_MBOX_CONTROL_EMPTY	BIT(17)

#define PMGR_RESET		BIT(31)
#define PMGR_PS_ACTUAL		GENMASK(7, 4)
#define PMGR_PS_ACTIVE		0xf

static void dump_fifos(void __iomem *mbox, const char *when)
{
	u32 a2i = readl_relaxed(mbox + ASC_MBOX_A2I_CONTROL);
	u32 i2a = readl_relaxed(mbox + ASC_MBOX_I2A_CONTROL);

	pr_info("sepcpu_start: %s: A2I=0x%08x [%s]  I2A=0x%08x [%s]\n", when,
		a2i, (a2i & ASC_MBOX_CONTROL_EMPTY) ? "empty" : "HAS DATA",
		i2a, (i2a & ASC_MBOX_CONTROL_EMPTY) ? "empty" : "HAS DATA");
}

static int __init sepcpu_start_init(void)
{
	void __iomem *asc = NULL, *mbox = NULL, *pmgr = NULL;
	u32 ps, cpu;
	int ret = -EAGAIN;
	int i;

	pmgr = ioremap(PMGR_PS_SEP_PHYS, 4);
	asc  = ioremap(SEP_ASC_PHYS, SEP_ASC_SIZE);
	mbox = ioremap(SEP_MBOX_PHYS, SEP_MBOX_SIZE);
	if (!pmgr || !asc || !mbox) {
		pr_err("sepcpu_start: ioremap failed\n");
		ret = -ENOMEM;
		goto out;
	}

	ps = readl_relaxed(pmgr);
	pr_info("sepcpu_start: pmgr ps_sep = 0x%08x (actual=0x%lx%s)\n", ps,
		FIELD_GET(PMGR_PS_ACTUAL, ps), (ps & PMGR_RESET) ? " RESET" : "");
	if ((ps & PMGR_RESET) || FIELD_GET(PMGR_PS_ACTUAL, ps) != PMGR_PS_ACTIVE) {
		pr_warn("sepcpu_start: power domain not active -- refusing to touch CPU_CONTROL\n");
		goto out;
	}

	cpu = readl_relaxed(asc + ASC_CPU_CONTROL);
	pr_info("sepcpu_start: CPU_CONTROL = 0x%08x (RUN %s)\n", cpu,
		(cpu & ASC_CPU_CONTROL_RUN) ? "set" : "clear");
	if (cpu & ASC_CPU_CONTROL_RUN) {
		pr_info("sepcpu_start: CPU already running -- writing nothing\n");
		dump_fifos(mbox, "state");
		goto out;
	}

	dump_fifos(mbox, "before");

	pr_info("sepcpu_start: setting CPU_CONTROL RUN bit\n");
	writel_relaxed(cpu | ASC_CPU_CONTROL_RUN, asc + ASC_CPU_CONTROL);
	readl_relaxed(asc + ASC_CPU_CONTROL);	/* post the write */

	for (i = 1; i <= 5; i++) {
		msleep(200);
		dump_fifos(mbox, "after");
	}

	cpu = readl_relaxed(asc + ASC_CPU_CONTROL);
	pr_info("sepcpu_start: CPU_CONTROL now = 0x%08x (RUN %s)\n", cpu,
		(cpu & ASC_CPU_CONTROL_RUN) ? "set" : "clear");
	pr_info("sepcpu_start: if the SEP woke, apple_sep should have logged 'RX ep=' lines\n");

out:
	if (mbox) iounmap(mbox);
	if (asc)  iounmap(asc);
	if (pmgr) iounmap(pmgr);
	return ret;
}

module_init(sepcpu_start_init);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Start the Apple SEP ASC CPU if halted");
