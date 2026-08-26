// SPDX-License-Identifier: GPL-2.0
/*
 * sepscan - is the SEP's ASC register block readable at all from the AP?
 *
 * CPU_CONTROL (0x44) reads 0x00000000 and silently discards a RUN write.
 * Two readings with the same symptom:
 *   (a) the register is real but write-protected by secure gating
 *   (b) there is no AP-facing CPU control here -- the SEP is not a plain ASC
 *
 * Distinguish by scanning. The mailbox at +0x8000 returns live data, so the
 * mapping works. If *everything* outside the mailbox reads as zero, the AP's
 * view of the SEP control registers is blocked wholesale, which favours (a)
 * and, either way, means no AP-side start is possible.
 *
 * Scans two small windows only. Reading unimplemented MMIO offsets can raise
 * an SError on these SoCs, so this deliberately does NOT sweep the whole
 * 0x6c000 region: just the ASC control area and a mailbox window as a known-
 * good positive control.
 *
 * Reads only.
 */
#include <linux/module.h>
#include <linux/io.h>

#define SEP_ASC_PHYS	0x25e400000ULL
#define SEP_ASC_SIZE	0x6c000

static int __init sepscan_init(void)
{
	void __iomem *base;
	static const struct { u32 start, end; const char *what; } win[] = {
		{ 0x00000, 0x00100, "ASC control (CPU_CONTROL lives at +0x44)" },
		{ 0x08000, 0x08100, "mailbox (positive control -- known live)" },
	};
	u32 off, v;
	int nonzero = 0, total = 0;
	unsigned int w;

	base = ioremap(SEP_ASC_PHYS, SEP_ASC_SIZE);
	if (!base) {
		pr_err("sepscan: ioremap failed\n");
		return -ENOMEM;
	}

	for (w = 0; w < ARRAY_SIZE(win); w++) {
		int wnz = 0;

		pr_info("sepscan: window +0x%05x..+0x%05x  %s\n",
			win[w].start, win[w].end, win[w].what);
		for (off = win[w].start; off < win[w].end; off += 4) {
			v = readl_relaxed(base + off);
			total++;
			if (v) {
				wnz++;
				nonzero++;
				pr_info("sepscan:   +0x%05x = 0x%08x\n", off, v);
			}
		}
		pr_info("sepscan:   -> %d non-zero in this window\n", wnz);
	}

	pr_info("sepscan: %d/%d words non-zero overall\n", nonzero, total);

	iounmap(base);
	return -EAGAIN;
}

module_init(sepscan_init);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Scan Apple SEP ASC register block for readable state");
