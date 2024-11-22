#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/fs.h>
#include <linux/mm.h>
#include <linux/bio.h>
#include <linux/bvec.h>
#include <linux/init.h>
#include <linux/wait.h>
#include <linux/stat.h>
#include <linux/slab.h>
#include <linux/numa.h>
#include <linux/errno.h>
#include <linux/types.h>
#include <linux/genhd.h>
#include <linux/blkdev.h>
#include <linux/string.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/vmalloc.h>
#include <linux/moduleparam.h>
#include <linux/spinlock_types.h>

#define SBDD_SECTOR_SHIFT      9
#define SBDD_SECTOR_SIZE       (1 << SBDD_SECTOR_SHIFT)
#define SBDD_NAME              "sbdd"
#define SBDD_TARGET_FLAGS      (FMODE_READ | FMODE_WRITE | FMODE_EXCL)

struct sbdd {
	wait_queue_head_t       exitwait;
	spinlock_t              datalock;
	atomic_t                deleting;
	atomic_t                refs_cnt;
	sector_t                capacity;
	struct gendisk          *gd;
	struct bio_set          bio_set;
	struct block_device     *target;
	char                    *target_path;
};

static struct sbdd      __sbdd;
static int              __sbdd_major = 0;
static char             *__sbdd_param_target_path = NULL;

static void sbdd_bio_end_io(struct bio *bio)
{
	struct bio *orig_bio = bio->bi_private;

	if (bio->bi_status)
		bio_io_error(orig_bio);
	else
		bio_endio(orig_bio);

	bio_put(bio);
}

static blk_qc_t sbdd_submit_bio(struct bio *bio)
{
	struct bio *clone = NULL;
	int ret = BLK_STS_OK;

	if (atomic_read(&__sbdd.deleting)) {
		pr_err("submit_bio error: device is deleting now\n");
		ret = BLK_STS_IOERR;
		goto out;
	}

	if (!atomic_inc_not_zero(&__sbdd.refs_cnt)) {
		pr_err("submit_bio error: device is busy\n");
		ret = BLK_STS_IOERR;
		goto out;
	}

	/*
	 * In reality target is not specified capacity will be 0.
	 * And when you try to write it will get -ENOSPC error
	 * and this function will not be called. But I will leave
	 * this check just in case.
	 */
	if (!__sbdd.target) {
		pr_warn("there are no associated target devices\n");

		/*
		 * It would be better to use BLK_STS_OFFLINE here, but this
		 * status was introduced in kernel 5.18.
		 */
		bio->bi_status = BLK_STS_TARGET;
		bio_endio(bio);
		ret = BLK_STS_TARGET;
		goto out;
	}

	clone = bio_clone_fast(bio, GFP_KERNEL, &__sbdd.bio_set);
	if (!clone) {
		pr_err("call bio_clone_fast() failed");
		bio_io_error(bio);
		ret = BLK_STS_IOERR;
		goto out;
	}

	clone->bi_private = bio;
	clone->bi_end_io = sbdd_bio_end_io;
	bio_set_dev(clone, __sbdd.target);
	submit_bio(clone);

out:
	if (atomic_dec_and_test(&__sbdd.refs_cnt))
		wake_up(&__sbdd.exitwait);

	return ret;
}

/*
There are no read or write operations. These operations are performed by
the request() function associated with the request queue of the disk.
*/
static struct block_device_operations const __sbdd_bdev_ops = {
	.owner          = THIS_MODULE,
	.submit_bio     = sbdd_submit_bio,
};

static int sbdd_get_target(const char *path)
{
	int ret = 0;
	struct block_device *bdev = NULL;
	sector_t capacity = 0;
	char *new_path;

	new_path = kstrdup(path, GFP_KERNEL);
	if (!new_path)
		return -ENOMEM;
	strim(new_path);

	bdev = blkdev_get_by_path(new_path, SBDD_TARGET_FLAGS, &__sbdd);
	if (IS_ERR(bdev)) {
		ret = PTR_ERR(bdev);
		pr_err("call blkdev_get_by_path() failed with %d\n", ret);
		goto out;
	}

	ret = bd_link_disk_holder(bdev, __sbdd.gd);
	if (ret) {
		pr_err("call bd_link_disk_holder() failed with %d\n", ret);
		goto out;
	}

	capacity = get_capacity(bdev->bd_disk);
	if (!capacity) {
		pr_err("wrong capacity\n");
		ret = -ENODEV;
		goto out_putbdev;
	}

	__sbdd.target = bdev;
	__sbdd.target_path = new_path;
	__sbdd.capacity = capacity;
	set_capacity(__sbdd.gd, __sbdd.capacity);

	return 0;

out_putbdev:
	blkdev_put(bdev, SBDD_TARGET_FLAGS);
out:
	return ret;
}

static void sbdd_put_target(void)
{
	if (__sbdd.target) {
		bd_unlink_disk_holder(__sbdd.target, __sbdd.gd);
		blkdev_put(__sbdd.target, SBDD_TARGET_FLAGS);
		kfree(__sbdd.target_path);
		__sbdd.target_path = NULL;
		__sbdd.target = NULL;
		__sbdd.capacity = 0;
	}
}

static ssize_t sbdd_sysfs_target_show(struct device *dev,
				      struct device_attribute *attr,
				      char *buf)
{
	if (!__sbdd.target_path)
		return sprintf(buf, "None\n");
	return sprintf(buf, "%s\n", __sbdd.target_path);
}

static ssize_t sbdd_sysfs_target_store(struct device *dev,
				       struct device_attribute *attr,
				       const char *buf, size_t count)
{
	int ret;

	sbdd_put_target();

	ret = sbdd_get_target(buf);
	if (ret) {
		pr_err("failed to set target\n");
		return ret;
	}

	return count;
}

static DEVICE_ATTR(target, 0644, sbdd_sysfs_target_show, sbdd_sysfs_target_store);

static int sbdd_create(void)
{
	int ret = 0;

	/*
	This call is somewhat redundant, but used anyways by tradition.
	The number is to be displayed in /proc/devices (0 for auto).
	*/
	pr_info("registering blkdev\n");
	__sbdd_major = register_blkdev(0, SBDD_NAME);
	if (__sbdd_major < 0) {
		pr_err("call register_blkdev() failed with %d\n", __sbdd_major);
		return -EBUSY;
	}

	memset(&__sbdd, 0, sizeof(struct sbdd));
	spin_lock_init(&__sbdd.datalock);
	init_waitqueue_head(&__sbdd.exitwait);


	/* A disk must have at least one minor */
	pr_info("allocating disk\n");
	__sbdd.gd = blk_alloc_disk(NUMA_NO_NODE);

	/* Configure gendisk */
	__sbdd.gd->major = __sbdd_major;
	__sbdd.gd->first_minor = 0;
	__sbdd.gd->minors = 1;
	__sbdd.gd->fops = &__sbdd_bdev_ops;

	/* Initialize bio_set */
	pr_info("initializing bio_set\n");
	ret = bioset_init(&__sbdd.bio_set, BIO_POOL_SIZE, 0, 0);
	if (ret) {
		pr_err("call bioset_init() failed\n");
		return ret;
	}

	/* Represents name in /proc/partitions and /sys/block */
	scnprintf(__sbdd.gd->disk_name, DISK_NAME_LEN, SBDD_NAME);

	/* Configure queue */
	blk_queue_logical_block_size(__sbdd.gd->queue, SBDD_SECTOR_SIZE);

	/* Open target device */
	if (__sbdd_param_target_path) {
		pr_info("getting target device");
		ret = sbdd_get_target(__sbdd_param_target_path);
		if (ret) {
			pr_err("target openning failed\n");
			return ret;
		}
	}

	atomic_set(&__sbdd.refs_cnt, 1);

	/*
	Allocating gd does not make it available, add_disk() required.
	After this call, gd methods can be called at any time. Should not be
	called before the driver is fully initialized and ready to process reqs.
	*/
	pr_info("adding disk\n");
	ret = add_disk(__sbdd.gd);
	if (ret)
		pr_err("call add_disk() failed!");

	/* Add the `target` parameter to /sys/block/sbdd */
	pr_info("creating /sys/block/sbdd/target\n");
	ret = device_create_file(disk_to_dev(__sbdd.gd), &dev_attr_target);
	if (ret) {
		pr_err("call device_create_file() failed with %d\n", ret);
		return ret;
	}

	return ret;
}

static void sbdd_delete(void)
{
	atomic_set(&__sbdd.deleting, 1);
	atomic_dec_if_positive(&__sbdd.refs_cnt);
	wait_event(__sbdd.exitwait, !atomic_read(&__sbdd.refs_cnt));

	if (__sbdd.target)
		sbdd_put_target();

	/* gd will be removed only after the last reference put */
	if (__sbdd.gd) {
		pr_info("deleting disk\n");
		del_gendisk(__sbdd.gd);
		put_disk(__sbdd.gd);
	}

	if (__sbdd.target_path)
		kfree(__sbdd.target_path);

	memset(&__sbdd, 0, sizeof(struct sbdd));

	if (__sbdd_major > 0) {
		pr_info("unregistering blkdev\n");
		unregister_blkdev(__sbdd_major, SBDD_NAME);
		__sbdd_major = 0;
	}
}

/*
Note __init is for the kernel to drop this function after
initialization complete making its memory available for other uses.
There is also __initdata note, same but used for variables.
*/
static int __init sbdd_init(void)
{
	int ret = 0;

	pr_info("starting initialization...\n");
	ret = sbdd_create();

	if (ret) {
		pr_warn("initialization failed\n");
		sbdd_delete();
	} else {
		pr_info("initialization complete\n");
	}

	return ret;
}

/*
Note __exit is for the compiler to place this code in a special ELF section.
Sometimes such functions are simply discarded (e.g. when module is built
directly into the kernel). There is also __exitdata note.
*/
static void __exit sbdd_exit(void)
{
	pr_info("exiting...\n");
	sbdd_delete();
	pr_info("exiting complete\n");
}

/* Called on module loading. Is mandatory. */
module_init(sbdd_init);

/* Called on module unloading. Unloading module is not allowed without it. */
module_exit(sbdd_exit);

/* Set target device path with insmod */
module_param_named(target, __sbdd_param_target_path, charp, 0644);
MODULE_PARM_DESC(target, "Target block device path");

/* Note for the kernel: a free license module. A warning will be outputted without it. */
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Simple Block Device Driver");
