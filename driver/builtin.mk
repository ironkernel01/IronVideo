# SPDX-License-Identifier: GPL-2.0-only
# Included by the U-Boot board or Linux DRM Makefile for a built-in driver.
ironvideo_driver_dir := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

ifneq ($(IRONFORGE_IRONVIDEO_UBOOT),)
ironvideo_uboot_dir := $(ironvideo_driver_dir)

obj-y += ironvideo_core.o

$(obj)/ironvideo_core.o: $(ironvideo_driver_dir)/ironvideo.c FORCE
	$(call if_changed_rule,cc_o_c)

ifneq ($(IRONVIDEO_BOOT_GLUE),)
include $(IRONVIDEO_BOOT_GLUE)
endif
else
obj-$(CONFIG_DRM_IRONVIDEO) += ironvideo_drm.o

$(obj)/ironvideo_drm.o: $(ironvideo_driver_dir)/ironvideo.c FORCE
	$(call if_changed_dep,cc_o_c)
endif
