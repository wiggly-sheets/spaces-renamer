.SECONDARY:
.PHONY: all install uninstall private-install clean

LDFLAGS := -g -mmacosx-version-min=10.10 -lc -F/System/Library/PrivateFrameworks
CFLAGS := -g -mmacosx-version-min=10.10 -I. -Werror -O3 -Wno-unknown-warning-option -Wno-deprecated-declarations -Wno-interrupt-service-routine
SYSROOT ?= $(shell xcodebuild -sdk macosx -version Path 2> /dev/null)
ifeq ($(SYSROOT),)
SYSROOT := $(shell find /Library/Developer/CommandLineTools/SDKs -maxdepth 1 -name "MacOSX1*.sdk" | sort -V | tail -n 1)
endif
CFLAGS += -isysroot $(SYSROOT)
SUBSTITUTE ?= YES

# Private runtime root. Upstream installs into /Library/Apple/System/Library/Frameworks/mip;
# the private build installs into its own root so it can coexist with a system MIP install.
MIP_ROOT ?= /Library/SpacesRenamer/mip

# Private identity. MIP_SERVICE_NAME is the Mach service the injectd daemon owns; it is baked
# into injectd_client.m / injectd.m and must match the MachServices key of the injectd plist.
MIP_SERVICE_NAME ?= com.wiggly-sheets.spaces-renamer.injectd
MIP_INJECTD_LABEL ?= com.wiggly-sheets.spaces-renamer.injectd
MIP_LSDINJECTOR_LABEL ?= com.wiggly-sheets.spaces-renamer.lsdinjector

# Build output directory. Kept out of the vendored tree so `git status` stays clean.
BUILD_DIR ?= build
B := $(BUILD_DIR)

# GNU binutils' gobjcopy turns the payload dylibs into raw .bin blobs. Not part of the Xcode
# toolchain: `brew install binutils` and make sure its bin directory is on PATH.
GOBJCOPY ?= gobjcopy

ifneq ($(SUBSTITUTE),YES)
ifneq ($(SUBSTITUTE),NO)
$(error SUBSTITUTE must be either YES or NO)
endif
endif

LOADER_SOURCES := loader/loader.m
ifeq ($(SUBSTITUTE),YES)
SUBSTITUTE_CFLAGS := -Ithird-party/substitute/lib -Ithird-party/substitute/vendor
LOADER_SOURCES += $(shell find third-party/substitute -name "*.c" -o -name "*.S")
endif

ifeq ($(shell uname -m),arm64)
ARCH1 := arm64e
ARCH2 := x86_64
DUAL_ARCH ?= 1
CFLAGS += -DROSETTA
else
ARCH1 := x86_64
ARCH2 := i386
endif


SIGN_IDENTITY ?= CodeSign
CODESIGN_TARGET := codesign -s "$(SIGN_IDENTITY)"

all: $(B)/lsdinjector.dylib $(B)/loader.dylib $(B)/inject $(B)/injectd \
     $(B)/$(MIP_INJECTD_LABEL).plist $(B)/$(MIP_LSDINJECTOR_LABEL).plist

$(B)/lsdinjector.dylib: $(B)/injector/lsd_injector.c.o $(B)/injector/injectd_client/injectd_client.m.o
	$(CC) $(LDFLAGS) -arch $(ARCH1) $^ -lbsm -framework Foundation -shared -o $@
	$(CODESIGN_TARGET) $@

$(B)/loader.dylib: $(LOADER_SOURCES)
	$(CC) $(CFLAGS) $(SUBSTITUTE_CFLAGS) $(LDFLAGS) -install_name @loader_path/../../../../loader.dylib -framework Foundation -shared -arch $(ARCH1) $(if $(DUAL_ARCH), -arch $(ARCH2)) $^ -o $@
	$(CODESIGN_TARGET) $@

$(B)/injectd: $(B)/injector/injector.o $(B)/injector/injectd.m.o | injector/injectd.entitlements
	mkdir -p $(dir $@)
	$(CC) $(LDFLAGS) -framework Foundation $^ -o $@ -arch $(ARCH1)
	$(CODESIGN_TARGET) --entitlements injector/injectd.entitlements $@

$(B)/inject: $(B)/injector/inject.c.o $(B)/injector/injectd_client/injectd_client.m.o
	mkdir -p $(dir $@)
	$(CC) $(LDFLAGS) -framework Foundation $^ -o $@ -arch $(ARCH1)
	$(CODESIGN_TARGET) $@

$(B)/injector/injector.o: $(B)/injector/inject/inject.c.o $(B)/injector/payloads/injected_$(ARCH1).c.bin $(B)/injector/payloads/injected_$(ARCH2).c.bin
	ld -r $(filter %.o,$^) -o $@ -sectcreate __INJ_$(ARCH1) __inj_$(ARCH1) $(B)/injector/payloads/injected_$(ARCH1).c.bin -sectcreate __INJ_$(ARCH2) __inj_$(ARCH2) $(B)/injector/payloads/injected_$(ARCH2).c.bin

$(B)/%.c.o: %.c
	mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -arch $(ARCH1) -c $^ -o $@

$(B)/%.m.o: %.m
	mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -fobjc-arc -arch $(ARCH1) -c $^ -o $@


$(B)/injector/payloads/injected_i386.c.dylib: injector/payloads/injected_i386.c
	mkdir -p $(dir $@)

	@# Fix the unaligned movaps LLVM bug, and convert iret to ret.
	$(CC) $(CFLAGS) -fno-exceptions -arch i386 -Oz $^ -S -o - \
		| sed "s/^	iret/	ret/g" \
		| sed "s/^	movaps	%xmm7, -32(%ebp)/	movaps	%xmm7, -40(%ebp)/g" \
		| sed "s/^	movaps	-32(%ebp), %xmm7/	movaps	-40(%ebp), %xmm7/g" \
		| clang -L. -Wl,-sectalign,__TEXT,__text,4000 -Wl,-order_file,injector/payloads/order -shared -isysroot $(SYSROOT) -xassembler - -arch i386 -o $@

$(B)/injector/payloads/injected_x86_64.c.dylib: injector/payloads/injected_x86_64.c
	mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -Wl,-sectalign,__TEXT,__text,4000 -fno-exceptions -shared -arch x86_64 -Oz -Wl,-order_file,injector/payloads/order $^ -o $@

$(B)/injector/payloads/injected_arm64e.c.dylib: injector/payloads/injected_arm64e.c
	mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -Wl,-sectalign,__TEXT,__text,4000 -fno-exceptions -shared -arch arm64e -Oz -Wl,-order_file,injector/payloads/order $^ -o $@

$(B)/injector/payloads/%.bin: $(B)/injector/payloads/%.dylib
	$(GOBJCOPY) -Obinary $^ $@

# Private LaunchDaemon plists. @MIP_ROOT@ and @MIP_SERVICE_NAME@ are substituted at build time.
$(B)/$(MIP_INJECTD_LABEL).plist: spacesrenamer.injectd.plist injector/injectd_client/mip_service_name.h
	mkdir -p $(dir $@)
	@grep -q "\"$(MIP_SERVICE_NAME)\"" injector/injectd_client/mip_service_name.h || \
		{ echo "MIP_SERVICE_NAME '$(MIP_SERVICE_NAME)' does not match injector/injectd_client/mip_service_name.h" >&2; exit 1; }
	sed -e "s=@MIP_ROOT@=$(MIP_ROOT)=g" -e "s=@MIP_SERVICE_NAME@=$(MIP_SERVICE_NAME)=g" $< > $@

$(B)/$(MIP_LSDINJECTOR_LABEL).plist: spacesrenamer.lsdinjector.plist
	mkdir -p $(dir $@)
	sed -e "s=@MIP_ROOT@=$(MIP_ROOT)=g" $< > $@

# The upstream `install`/`uninstall` targets would overwrite a system MIP install
# (/Library/Apple/System/Library/Frameworks/mip, /usr/local/bin/inject). This vendored copy is
# private-only, so they are disabled. Use `make private-install` instead.
install uninstall:
	@echo "The upstream install/uninstall targets are disabled in this vendored copy." >&2
	@echo "They would overwrite a system MIP install. Use 'make private-install' (root) instead." >&2
	@false

# Installs the private runtime into $(MIP_ROOT) and registers the private LaunchDaemons.
# Must run as root; it does not touch the system MIP install, /usr/local/bin or ~/Library/MIP.
private-install: all
	sudo ./install-private.sh "$(MIP_ROOT)" "$(B)" "$(MIP_INJECTD_LABEL)" "$(MIP_LSDINJECTOR_LABEL)"

clean:
	rm -rf $(B)
