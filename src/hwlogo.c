// SPDX-License-Identifier: GPL-2.0
/*
 * hwlogo - lid "Logo light" for HUAWEI MateBook GT 14 (ENZH-XX).
 *
 * The HUAWEI wordmark on the lid is driven by the embedded controller.  The
 * vendor firmware exposes it through the WMI command pair GLGS/SLGS
 * (0x0509/0x050a in SSDT18, "Get/Set LGS"), implemented as:
 *
 *	SLGS: EC[0xA5] <- 0x00  (logo light off, EC[0xA4] then reads 0x01)
 *	SLGS: EC[0xA5] <- 0x01  (logo light on,  EC[0xA4] then reads 0x02)
 *	GLGS: reads EC[0xA4]
 *
 * The EC is reached through the firmware method \_SB.PC00.LPCB.HWEC.ECCD(),
 * which speaks a small mailbox protocol on ports 0x68 (data) / 0x6C (status):
 *
 *	byte 0  cmd      0x02 = EC RAM access
 *	byte 1  offset   register
 *	byte 2  length   payload bytes (0 for a single byte read)
 *	...     payload  data for writes
 *	reply            [status, length, data...]   (status 0 = ok)
 *
 * Going through ECCD instead of poking the ports keeps the firmware's EC
 * mutex, retries and timeouts in charge, and works with Secure Boot enabled
 * (raw port access is forbidden by kernel lockdown).
 *
 * Exposes a standard LED class device: /sys/class/leds/huawei::logo
 */

#include <linux/acpi.h>
#include <linux/leds.h>
#include <linux/module.h>
#include <linux/mutex.h>

#define HWLOGO_EC_PATH		"\\_SB.PC00.LPCB.HWEC.ECCD"
#define HWLOGO_CMD_ECRAM	0x02
#define HWLOGO_REPLY_MAX	256

static unsigned int reg = 0xa5;
module_param(reg, uint, 0644);
MODULE_PARM_DESC(reg, "EC register used to write the logo light state");

static unsigned int state_reg = 0xa4;
module_param(state_reg, uint, 0644);
MODULE_PARM_DESC(state_reg, "EC register reporting the logo light state");

static unsigned int on_value = 0x01;
module_param(on_value, uint, 0444);
MODULE_PARM_DESC(on_value, "byte written to reg to switch the light on");

static unsigned int off_value = 0x00;
module_param(off_value, uint, 0444);
MODULE_PARM_DESC(off_value, "byte written to reg to switch the light off");

static DEFINE_MUTEX(hwlogo_mutex);
static struct led_classdev hwlogo_led;

/**
 * hwlogo_xfer() - run one EC mailbox transaction through the firmware method.
 * @off:	EC register
 * @len:	payload length (0 = single byte read)
 * @data:	payload bytes for writes
 * @reply:	buffer receiving the raw firmware reply
 * @reply_len:	in: size of @reply, out: bytes received
 *
 * Return: 0 on success, negative errno otherwise.
 */
static int hwlogo_xfer(u8 off, u8 len, const u8 *data,
		       u8 *reply, size_t *reply_len)
{
	union acpi_object args[5];
	struct acpi_object_list arg_list = { .count = ARRAY_SIZE(args), .pointer = args };
	struct acpi_buffer ret = { ACPI_ALLOCATE_BUFFER, NULL };
	union acpi_object *obj;
	acpi_handle handle;
	acpi_status status;
	u8 dummy = 0;
	size_t copy;
	int err = 0;

	status = acpi_get_handle(NULL, HWLOGO_EC_PATH, &handle);
	if (ACPI_FAILURE(status))
		return -ENODEV;

	memset(args, 0, sizeof(args));
	args[0].type = ACPI_TYPE_INTEGER;
	args[0].integer.value = HWLOGO_CMD_ECRAM;
	args[1].type = ACPI_TYPE_INTEGER;
	args[1].integer.value = off;
	args[2].type = ACPI_TYPE_INTEGER;
	args[2].integer.value = len;
	/* the firmware method does "IBUF = Arg3" before writing anything, so it
	 * needs a real buffer even for pure reads
	 */
	args[3].type = ACPI_TYPE_BUFFER;
	args[3].buffer.length = len ? len : 1;
	args[3].buffer.pointer = len ? (u8 *)data : &dummy;
	args[4].type = ACPI_TYPE_INTEGER;
	args[4].integer.value = HWLOGO_REPLY_MAX;

	status = acpi_evaluate_object(handle, NULL, &arg_list, &ret);
	if (ACPI_FAILURE(status)) {
		pr_err("hwlogo: EC 0x%02x len %u: %s\n", off, len,
		       acpi_format_exception(status));
		err = -EIO;
		goto out;
	}

	obj = ret.pointer;
	if (obj->type != ACPI_TYPE_BUFFER || obj->buffer.length < 3) {
		pr_err("hwlogo: EC 0x%02x: unexpected reply (type %u, len %u)\n",
		       off, obj->type,
		       obj->type == ACPI_TYPE_BUFFER ? obj->buffer.length : 0);
		err = -EIO;
		goto out;
	}

	copy = min_t(size_t, obj->buffer.length, *reply_len);
	memcpy(reply, obj->buffer.pointer, copy);
	*reply_len = copy;
	if (reply[0] != 0) {
		err = -ENXIO;	/* EC: register not supported */
		goto out;
	}

	pr_debug("hwlogo: EC 0x%02x <- %u bytes: %*ph\n", off, len, len, data);
out:
	kfree(ret.pointer);
	return err;
}

static int hwlogo_ec_read(u8 off, u8 *out)
{
	u8 reply[HWLOGO_REPLY_MAX];
	size_t reply_len = sizeof(reply);
	int err;

	mutex_lock(&hwlogo_mutex);
	err = hwlogo_xfer(off, 0, NULL, reply, &reply_len);
	mutex_unlock(&hwlogo_mutex);
	if (err)
		return err;
	if (reply_len < 3 || reply[1] < 1)
		return -EIO;
	*out = reply[2];
	return 0;
}

static int hwlogo_ec_write(u8 off, u8 val)
{
	u8 reply[HWLOGO_REPLY_MAX];
	size_t reply_len = sizeof(reply);
	int err;

	mutex_lock(&hwlogo_mutex);
	err = hwlogo_xfer(off, 1, &val, reply, &reply_len);
	mutex_unlock(&hwlogo_mutex);
	return err;
}

static enum led_brightness hwlogo_brightness_get(struct led_classdev *cdev)
{
	u8 v;

	if (hwlogo_ec_read((u8)state_reg, &v))
		return LED_OFF;

	/* EC state register: 0x01 = off, 0x02 = on */
	return v >= 2 ? LED_FULL : LED_OFF;
}

static int hwlogo_brightness_set(struct led_classdev *cdev, enum led_brightness value)
{
	u8 val = (value == LED_OFF) ? off_value : on_value;

	return hwlogo_ec_write((u8)reg, val);
}

static ssize_t ec_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	u8 v;
	int err = hwlogo_ec_read((u8)state_reg, &v);

	if (err)
		return err;
	return sysfs_emit(buf, "EC[0x%02x]=0x%02x\n", state_reg, v);
}
static DEVICE_ATTR_RO(ec);

static struct attribute *hwlogo_attrs[] = { &dev_attr_ec.attr, NULL };
ATTRIBUTE_GROUPS(hwlogo);

static int __init hwlogo_init(void)
{
	int err;

	hwlogo_led.name = "huawei::logo";
	hwlogo_led.max_brightness = 1;
	hwlogo_led.brightness_get = hwlogo_brightness_get;
	hwlogo_led.brightness_set_blocking = hwlogo_brightness_set;
	hwlogo_led.flags = LED_CORE_SUSPENDRESUME | LED_RETAIN_AT_SHUTDOWN;
	hwlogo_led.groups = hwlogo_groups;

	err = led_classdev_register(NULL, &hwlogo_led);
	if (err)
		pr_err("hwlogo: cannot register LED: %d\n", err);
	return err;
}
module_init(hwlogo_init);

static void __exit hwlogo_exit(void)
{
	led_classdev_unregister(&hwlogo_led);
}
module_exit(hwlogo_exit);

MODULE_AUTHOR("Yegor Chuperka <yegor-chuperka@yandex.ru>");
MODULE_DESCRIPTION("HUAWEI MateBook lid logo light");
MODULE_LICENSE("GPL");
