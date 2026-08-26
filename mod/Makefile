KDIR ?= $(CURDIR)/../build/linux-asahi-7.1.6
obj-m := sepmbox_peek.o sepcpu_start.o sepscan.o sepfwpeek.o
all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules
clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
