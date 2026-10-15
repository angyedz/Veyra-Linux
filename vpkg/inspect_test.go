package main

import (
	"debug/elf"
	"encoding/binary"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestInspectELFReportsGlibcRuntime(t *testing.T) {
	path := filepath.Join(t.TempDir(), "program")
	if err := writeELFFixture(path, "/lib64/ld-linux-x86-64.so.2"); err != nil {
		t.Fatal(err)
	}

	info, err := inspectELF(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.architecture != "x86_64" || info.runtime != "glibc" {
		t.Fatalf("inspection = %#v", info)
	}
	if info.interpreter != "/lib64/ld-linux-x86-64.so.2" {
		t.Fatalf("interpreter = %q", info.interpreter)
	}
}

func TestInspectELFRejectsNonELF(t *testing.T) {
	path := filepath.Join(t.TempDir(), "not-elf")
	if err := os.WriteFile(path, []byte("text"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := inspectELF(path); err == nil || !strings.Contains(err.Error(), "not a readable ELF") {
		t.Fatalf("inspect error = %v", err)
	}
}

func TestCompareVersionNumbers(t *testing.T) {
	for _, test := range []struct {
		a, b string
		want int
	}{{"2.9", "2.10", -1}, {"2.10", "2.9", 1}, {"2.10", "2.10.0", 0}} {
		if got := compareVersionNumbers(test.a, test.b); got != test.want {
			t.Errorf("compareVersionNumbers(%q, %q) = %d, want %d", test.a, test.b, got, test.want)
		}
	}
}

func TestMissingLibrariesChecksOnlySysrootDirectories(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "libpresent.so"), []byte("fixture"), 0o600); err != nil {
		t.Fatal(err)
	}
	got := missingLibraries([]string{"libpresent.so", "libmissing.so", "../escape.so"}, []string{dir})
	want := []string{"../escape.so", "libmissing.so"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("missingLibraries() = %#v, want %#v", got, want)
	}
}

func writeELFFixture(path, interpreter string) error {
	interp := append([]byte(interpreter), 0)
	data := make([]byte, 120+len(interp))
	copy(data[:7], []byte{0x7f, 'E', 'L', 'F', 2, 1, 1})
	binary.LittleEndian.PutUint16(data[16:18], uint16(elf.ET_DYN))
	binary.LittleEndian.PutUint16(data[18:20], uint16(elf.EM_X86_64))
	binary.LittleEndian.PutUint32(data[20:24], 1)
	binary.LittleEndian.PutUint64(data[32:40], 64)
	binary.LittleEndian.PutUint16(data[52:54], 64)
	binary.LittleEndian.PutUint16(data[54:56], 56)
	binary.LittleEndian.PutUint16(data[56:58], 1)
	binary.LittleEndian.PutUint32(data[64:68], uint32(elf.PT_INTERP))
	binary.LittleEndian.PutUint64(data[72:80], 120)
	binary.LittleEndian.PutUint64(data[96:104], uint64(len(interp)))
	binary.LittleEndian.PutUint64(data[104:112], uint64(len(interp)))
	copy(data[120:], interp)
	return os.WriteFile(path, data, 0o600)
}
