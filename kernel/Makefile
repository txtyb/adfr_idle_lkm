obj-m := adfr_idle.o

KDIR := $(KDIR)
MDIR := $(realpath $(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
VER ?= local
ODIR := $(MDIR)/out/$(VER)

adfr_idle-y := src/adfr_idle.o

ccflags-y += -std=gnu11
ccflags-y += -Wno-declaration-after-statement
ccflags-y += -Wno-unused-function
ccflags-y += -Wno-strict-prototypes
ccflags-y += -Wno-int-conversion
ccflags-y += -Wno-gcc-compat
ccflags-y += -Wno-missing-prototypes
ccflags-y += -Wno-unused-variable

$(info -- KDIR: $(KDIR))
$(info -- MDIR: $(MDIR))
$(info -- ODIR: $(ODIR))

.PHONY: all clean

all:
	$(MAKE) -C $(KDIR) M=$(ODIR) src=$(MDIR) srcroot=$(MDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(ODIR) src=$(MDIR) srcroot=$(MDIR) clean

# redirect subdir objects onto src/, same trick as the reference project
$(obj)/%.o: $(src)/%.c FORCE
	$(call if_changed_rule,cc_o_c)
	$(call cmd,force_checksrc)
