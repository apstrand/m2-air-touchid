// SPDX-License-Identifier: GPL-2.0
/*
 * sepfwpeek - did iBoot actually stage SEP firmware into the sepfw region?
 *
 * The iboot-manifest enumerates every firmware object iBoot loads and verifies
 * (aopf, avef, dcp2, ispf, krnl, mtpf, pmpf, siof, ...) and contains NO SEP
 * firmware entry. Yet m1n1 found a SEPFW range in the ADT memory map and
 * reserved it (0x8037c0000 + 0x5a0000, 5760 KiB).
 *
 * If the region holds an IMG4 container ("IM4P"), iBoot staged SEP firmware and
 * the halt is elsewhere. If it is zeros, iBoot never loaded SEP firmware for
 * this boot at all -- which would explain why the SEP is sitting halted.
 *
 * Reads only.
 */
#include <linux/module.h>
#include <linux/io.h>

#define SEPFW_PHYS	0x8037c0000ULL
#define SEPFW_SIZE	0x5a0000
#define SCAN		0x10000		/* how much to survey for non-zero content */

static int __init sepfwpeek_init(void)
{
	void *base;
	const u8 *p;
	size_t i, nonzero = 0, first = SCAN;

	base = memremap(SEPFW_PHYS, SCAN, MEMREMAP_WB);
	if (!base) {
		pr_err("sepfwpeek: memremap failed\n");
		return -ENOMEM;
	}
	p = base;

	pr_info("sepfwpeek: sepfw region 0x%llx + 0x%x, surveying first 0x%x bytes\n",
		SEPFW_PHYS, SEPFW_SIZE, SCAN);
	pr_info("sepfwpeek: first 32 bytes: %*ph\n", 32, p);
	pr_info("sepfwpeek: as ascii: %.16s\n", (const char *)p);

	for (i = 0; i < SCAN; i++) {
		if (p[i]) {
			if (first == SCAN)
				first = i;
			nonzero++;
		}
	}

	pr_info("sepfwpeek: %zu/%d bytes non-zero", nonzero, SCAN);
	if (nonzero)
		pr_cont(", first non-zero at +0x%zx\n", first);
	else
		pr_cont(" -- region is entirely EMPTY\n");

	/* IMG4 containers start with a DER SEQUENCE then the IA5String "IM4P"/"IM4M" */
	if (p[0] == 0x30 && memchr(p, 'I', 16))
		pr_info("sepfwpeek: looks like a DER/IMG4 container -> firmware IS staged\n");
	else if (!nonzero)
		pr_info("sepfwpeek: VERDICT: no SEP firmware was staged for this boot\n");
	else
		pr_info("sepfwpeek: non-zero but not an obvious IMG4 header -- see bytes above\n");

	memunmap(base);
	return -EAGAIN;
}

module_init(sepfwpeek_init);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Check whether iBoot staged SEP firmware");
