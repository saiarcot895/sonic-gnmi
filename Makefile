ifeq ($(GOPATH),)
export GOPATH=/tmp/go
endif
export PATH := $(PATH):$(GOPATH)/bin

INSTALL := /usr/bin/install
DBDIR := /var/run/redis/sonic-db/
GO ?= /usr/local/go/bin/go
TOP_DIR := $(abspath ..)
MGMT_COMMON_DIR := $(TOP_DIR)/sonic-mgmt-common
BUILD_DIR := build/bin
export CVL_SCHEMA_PATH := $(MGMT_COMMON_DIR)/build/cvl/schema
export GOBIN := $(abspath $(BUILD_DIR))
export PATH := $(PATH):$(GOBIN):$(shell dirname $(GO))
export CGO_LDFLAGS := $(CGO_LDFLAGS) -lswsscommon -lhiredis
export CGO_CXXFLAGS := $(CGO_CXXFLAGS) -I/usr/include/swss -Wall -fpermissive

SRC_FILES=$(shell find . -name '*.go' | grep -v '_test.go' | grep -v '/tests/')
TEST_FILES=$(wildcard *_test.go)
TELEMETRY_TEST_DIR = build/tests/gnmi_server
TELEMETRY_TEST_BIN = $(TELEMETRY_TEST_DIR)/server.test
ifeq ($(ENABLE_TRANSLIB_WRITE),y)
BLD_TAGS := gnmi_translib_write
endif
ifeq ($(ENABLE_NATIVE_WRITE),y)
BLD_TAGS := $(BLD_TAGS) gnmi_native_write
endif

ifneq ($(BLD_TAGS),)
BLD_FLAGS := -tags "$(strip $(BLD_TAGS))"
endif

GO_DEPS := vendor/.done
PATCHES := $(wildcard patches/*.patch)
PATCHES += $(shell find $(MGMT_COMMON_DIR)/patches -type f)

all: sonic-gnmi $(TELEMETRY_TEST_BIN)

go.mod:
	$(GO) mod init github.com/sonic-net/sonic-gnmi

$(GO_DEPS): go.mod $(PATCHES) swsscommon_wrap
	$(GO) mod vendor
	$(GO) mod download golang.org/x/crypto@v0.0.0-20191206172530-e9b2fee46413
	$(GO) mod download github.com/jipanyang/gnxi@v0.0.0-20181221084354-f0a90cca6fd0
	cp -r $(GOPATH)/pkg/mod/golang.org/x/crypto@v0.0.0-20191206172530-e9b2fee46413/* vendor/golang.org/x/crypto/
	cp -r $(GOPATH)/pkg/mod/github.com/jipanyang/gnxi@v0.0.0-20181221084354-f0a90cca6fd0/* vendor/github.com/jipanyang/gnxi/
	$(MGMT_COMMON_DIR)/patches/apply.sh vendor
	chmod -R u+w vendor
	patch -d vendor -p0 < patches/gnmi_cli.all.patch
	patch -d vendor -p0 < patches/gnmi_set.patch
	patch -d vendor -p0 < patches/gnmi_get.patch
	patch -d vendor -p0 < patches/gnmi_path.patch
	patch -d vendor -p0 < patches/gnmi_xpath.patch
	git apply patches/0001-Updated-to-filter-and-write-to-file.patch
	touch $@

go-deps: $(GO_DEPS)

go-deps-clean:
	$(RM) -r vendor


define build_golang
	@ # Taken from https://gitlab.com/gitlab-org/gitaly/-/merge_requests/4192
	@ #
	@ # To compute a unique and deterministic value for GNU build-id, we build the Go binary a second time.
	@ # From the first build, we extract its unique and deterministic Go build-id, and use that to derive
	@ # comparably unique and deterministic GNU build-id to inject into the final binary.
	@ # If we cannot extract a Go build-id, we punt and fallback to using a random 32-byte hex string.
	@ # This fallback is unique but non-deterministic, making it sufficient to avoid generating the
	@ # GNU build-id from the empty string and causing guaranteed collisions.
	$(GO) install -trimpath -mod=vendor $2 $1
	GO_BUILD_ID=$$( $(GO) tool buildid ${GOBIN}/$(notdir $1) || openssl rand -hex 32 ) && \
	GNU_BUILD_ID=$$( echo $$GO_BUILD_ID | sha1sum | cut -d' ' -f1 ) && \
	$(GO) install -trimpath -ldflags "-B 0x$$GNU_BUILD_ID" -mod vendor $1
endef

sonic-gnmi: $(GO_DEPS)
ifeq ($(CROSS_BUILD_ENVIRON),y)
	$(GO) build -o ${GOBIN}/telemetry -mod=vendor $(BLD_FLAGS) github.com/sonic-net/sonic-gnmi/telemetry
	$(GO) build -o ${GOBIN}/dialout_client_cli -mod=vendor $(BLD_FLAGS) github.com/sonic-net/sonic-gnmi/dialout/dialout_client_cli
	$(GO) build -o ${GOBIN}/gnmi_get -mod=vendor github.com/jipanyang/gnxi/gnmi_get
	$(GO) build -o ${GOBIN}/gnmi_set -mod=vendor github.com/jipanyang/gnxi/gnmi_set
	$(GO) build -o ${GOBIN}/gnmi_cli -mod=vendor github.com/openconfig/gnmi/cmd/gnmi_cli
	$(GO) build -o ${GOBIN}/gnoi_client -mod=vendor github.com/sonic-net/sonic-gnmi/gnoi_client
	$(GO) build -o ${GOBIN}/gnmi_dump -mod=vendor github.com/sonic-net/sonic-gnmi/gnmi_dump
else
	$(call build_golang,github.com/sonic-net/sonic-gnmi/telemetry,$(BLD_FLAGS))
	$(call build_golang,github.com/sonic-net/sonic-gnmi/dialout/dialout_client_cli,$(BLD_FLAGS))
	$(call build_golang,github.com/jipanyang/gnxi/gnmi_get,)
	$(call build_golang,github.com/jipanyang/gnxi/gnmi_set,)
	$(call build_golang,github.com/openconfig/gnmi/cmd/gnmi_cli)
	$(call build_golang,github.com/sonic-net/sonic-gnmi/gnoi_client)
	$(call build_golang,github.com/sonic-net/sonic-gnmi/gnmi_dump)
endif

swsscommon_wrap:
	make -C swsscommon

DBCONFG = $(DBDIR)/database_config.json
ENVFILE = build/test/env.txt
TESTENV = $(shell cat $(ENVFILE))

$(DBCONFG): testdata/database_config.json
	sudo mkdir -p ${DBDIR}
	sudo cp ./testdata/database_config.json ${DBDIR}

$(ENVFILE):
	mkdir -p $(@D)
	tools/test/env.sh | grep -v DB_CONFIG_PATH | tee $@

check_gotest: $(DBCONFG) $(ENVFILE)
	sudo CGO_LDFLAGS="$(CGO_LDFLAGS)" CGO_CXXFLAGS="$(CGO_CXXFLAGS)" $(GO) test -race -coverprofile=coverage-config.txt -covermode=atomic -v github.com/sonic-net/sonic-gnmi/sonic_db_config
	sudo CGO_LDFLAGS="$(CGO_LDFLAGS)" CGO_CXXFLAGS="$(CGO_CXXFLAGS)" $(TESTENV) $(GO) test -race -coverprofile=coverage-gnmi.txt -covermode=atomic -mod=vendor $(BLD_FLAGS) -v github.com/sonic-net/sonic-gnmi/gnmi_server -coverpkg ../...
	sudo CGO_LDFLAGS="$(CGO_LDFLAGS)" CGO_CXXFLAGS="$(CGO_CXXFLAGS)" $(TESTENV) $(GO) test -coverprofile=coverage-dialcout.txt -covermode=atomic -mod=vendor $(BLD_FLAGS) -v github.com/sonic-net/sonic-gnmi/dialout/dialout_client
	sudo CGO_LDFLAGS="$(CGO_LDFLAGS)" CGO_CXXFLAGS="$(CGO_CXXFLAGS)" $(GO) test -race -coverprofile=coverage-data.txt -covermode=atomic -mod=vendor -v github.com/sonic-net/sonic-gnmi/sonic_data_client
	sudo CGO_LDFLAGS="$(CGO_LDFLAGS)" CGO_CXXFLAGS="$(CGO_CXXFLAGS)" $(GO) test -race -coverprofile=coverage-dbus.txt -covermode=atomic -mod=vendor -v github.com/sonic-net/sonic-gnmi/sonic_service_client
	sudo CGO_LDFLAGS="$(CGO_LDFLAGS)" CGO_CXXFLAGS="$(CGO_CXXFLAGS)" $(TESTENV) $(GO) test -race -coverprofile=coverage-translutils.txt -covermode=atomic -mod=vendor -v github.com/sonic-net/sonic-gnmi/transl_utils
	$(GO) get github.com/axw/gocov/...
	$(GO) get github.com/AlekSi/gocov-xml
	$(GO) mod vendor
	gocov convert coverage-*.txt | gocov-xml -source $(shell pwd) > coverage.xml
	rm -rf coverage-*.txt 

clean:
	$(RM) -r build
	$(RM) -r vendor

$(TELEMETRY_TEST_BIN): $(TEST_FILES) $(SRC_FILES)
	mkdir -p $(@D)
	cp -r testdata $(@D)/
ifeq ($(CONFIGURED_ARCH),armhf)
	touch $@
else
	$(GO) test -mod=vendor $(BLD_FLAGS) -c -cover github.com/sonic-net/sonic-gnmi/gnmi_server -o $@
endif

install:
	$(INSTALL) -D $(BUILD_DIR)/telemetry $(DESTDIR)/usr/sbin/telemetry
	$(INSTALL) -D $(BUILD_DIR)/dialout_client_cli $(DESTDIR)/usr/sbin/dialout_client_cli
	$(INSTALL) -D $(BUILD_DIR)/gnmi_get $(DESTDIR)/usr/sbin/gnmi_get
	$(INSTALL) -D $(BUILD_DIR)/gnmi_set $(DESTDIR)/usr/sbin/gnmi_set
	$(INSTALL) -D $(BUILD_DIR)/gnmi_cli $(DESTDIR)/usr/sbin/gnmi_cli
	$(INSTALL) -D $(BUILD_DIR)/gnoi_client $(DESTDIR)/usr/sbin/gnoi_client
	$(INSTALL) -D $(BUILD_DIR)/gnmi_dump $(DESTDIR)/usr/sbin/gnmi_dump


deinstall:
	rm $(DESTDIR)/usr/sbin/telemetry
	rm $(DESTDIR)/usr/sbin/dialout_client_cli
	rm $(DESTDIR)/usr/sbin/gnmi_get
	rm $(DESTDIR)/usr/sbin/gnmi_set
	rm $(DESTDIR)/usr/sbin/gnoi_client
	rm $(DESTDIR)/usr/sbin/gnmi_dump


