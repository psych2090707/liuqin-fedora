// SPDX-License-Identifier: GPL-2.0-only
/* Read-only adapter for the vendor PON FIFO, no reset or PMIC configuration.
 * Layout: MiCode liuqin-t-oss drivers/soc/qcom/pmic-pon-log.c.
 * Use the existing NVMEM consumer API: the SDAM provider validates 0x40..0xbf,
 * but its sysfs size=128 truncates reads at 0x80 in this locked kernel.
 */
#include <linux/device.h>
#include <linux/err.h>
#include <linux/module.h>
#include <linux/nvmem-consumer.h>
#include <linux/of.h>

static char raw_hex[257];
module_param_string(raw_hex, raw_hex, sizeof(raw_hex), 0400);
MODULE_PARM_DESC(raw_hex, "Frozen SDAM bytes at offsets 0x40..0xbf, hex, read only");

static int match_node(struct device *dev, const void *data)
{
	return dev->of_node == data;
}

static int __init afk_pon_init(void)
{
	struct device_node *vendor, *expected, *active;
	struct nvmem_device *nvmem;
	u8 raw[128];
	u32 reg;
	int ret, i;

	vendor = of_find_node_by_path("/liuqin-abl-overlay-sink/pmic-pon-log");
	if (!vendor || !of_device_is_compatible(vendor, "qcom,pmic-pon-log")) {
		of_node_put(vendor);
		return -ENODEV;
	}
	expected = of_parse_phandle(vendor, "nvmem", 0);
	of_node_put(vendor);
	ret = of_property_read_u32(expected, "reg", &reg);
	of_node_put(expected);
	if (ret || reg != 0x7400)
		return -ENODEV;
	active = of_find_node_by_path("/soc@0/spmi@c400000/pmic@0/nvram@7400");
	if (!active)
		return -ENODEV;
	nvmem = nvmem_device_find(active, match_node);
	of_node_put(active);
	if (IS_ERR(nvmem))
		return PTR_ERR(nvmem);
	ret = nvmem_device_read(nvmem, 0x40, sizeof(raw), raw);
	nvmem_device_put(nvmem);
	if (ret != sizeof(raw))
		return ret < 0 ? ret : -EIO;
	for (i = 0; i < sizeof(raw); i++)
		snprintf(raw_hex + 2 * i, 3, "%02x", raw[i]);
	pr_info("afk_pon_snapshot: captured 128 read-only PON SDAM bytes\n");
	return 0;
}

static void __exit afk_pon_exit(void) {}
module_init(afk_pon_init);
module_exit(afk_pon_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Liuqin read-only PON SDAM snapshot via existing NVMEM driver");
