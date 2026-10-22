package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestParse(t *testing.T) {
	s, p, e := parse([]string{"firefox", "--from", "nix"})
	if e != nil || s != "nix" || len(p) != 1 || p[0] != "firefox" {
		t.Fatalf("parse: %s %v %v", s, p, e)
	}
	for _, bad := range [][]string{{"--from", "invalid"}, {"--bad"}, {"--from"}} {
		if _, _, e := parse(bad); e == nil {
			t.Fatalf("accepted %v", bad)
		}
	}
}

func TestDispatch(t *testing.T) {
	useUserEnvironment(t, true)
	dir := t.TempDir()
	log := filepath.Join(dir, "commands")
	for _, name := range []string{"apk", "nix"} {
		script := "#!/bin/sh\nprintf '%s\\n' \"" + name + " $*\" >> \"$VPKG_TEST_LOG\"\n"
		if e := os.WriteFile(filepath.Join(dir, name), []byte(script), 0755); e != nil {
			t.Fatal(e)
		}
	}
	t.Setenv("PATH", dir+":"+os.Getenv("PATH"))
	t.Setenv("VPKG_TEST_LOG", log)
	for _, tc := range []struct {
		cmd, source string
		args        []string
	}{
		{"install", "alpine", []string{"firefox"}},
		{"upgrade", "alpine", nil},
		{"install", "nix", []string{"helix"}},
		{"upgrade", "nix", nil},
	} {
		if e := dispatch(tc.cmd, tc.source, tc.args); e != nil {
			t.Fatal(e)
		}
	}
	b, e := os.ReadFile(log)
	if e != nil {
		t.Fatal(e)
	}
	for _, want := range []string{"apk add firefox", "apk upgrade", "nix profile install nixpkgs#helix", "nix profile upgrade --all"} {
		if !strings.Contains(string(b), want) {
			t.Fatalf("missing %q: %s", want, b)
		}
	}
}

func TestInstallAutomaticallyPrefersAlpineThenVeyraThenNix(t *testing.T) {
	dir := t.TempDir()
	repositories := filepath.Join(dir, "repositories")
	if err := os.WriteFile(repositories, []byte(
		"https://dl-cdn.alpinelinux.org/alpine/v3.22/main\n"+
			"@veyra https://packages.veyra.example/veyra-pkgrepo\n",
	), 0600); err != nil {
		t.Fatal(err)
	}
	log := filepath.Join(dir, "commands")
	apk := `#!/bin/sh
set -eu
repositories=
if [ "${1:-}" = "--repositories-file" ]; then
    repositories=$2
    shift 2
fi
command=$1
shift
repo_list=$(tr '\n' ',' < "$repositories")
case "$command" in
    update|add)
        printf 'apk %s %s repositories=%s\n' "$command" "$*" "$repo_list" >> "$VPKG_TEST_LOG"
        ;;
    search)
        package=
        for argument in "$@"; do package=$argument; done
        printf 'search %s repositories=%s\n' "$package" "$repo_list" >> "$VPKG_TEST_LOG"
        case "$repo_list" in
            *veyra-pkgrepo*) available=$VPKG_TEST_VEYRA_PACKAGES ;;
            *) available=$VPKG_TEST_ALPINE_PACKAGES ;;
        esac
        case " $available " in
            *" $package "*) printf '%s\n' "$package" ;;
        esac
        ;;
    *) exit 2 ;;
esac
`
	for _, name := range []string{"apk", "vpkg-engine"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(apk), 0755); err != nil {
			t.Fatal(err)
		}
	}
	nix := "#!/bin/sh\nprintf 'nix %s\\n' \"$*\" >> \"$VPKG_TEST_LOG\"\n"
	if err := os.WriteFile(filepath.Join(dir, "nix"), []byte(nix), 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("VPKG_APK_REPOSITORIES_FILE", repositories)
	t.Setenv("VPKG_TEST_LOG", log)
	t.Setenv("VPKG_TEST_ALPINE_PACKAGES", "alpine-only")
	t.Setenv("VPKG_TEST_VEYRA_PACKAGES", "alpine-only veyra-only")

	if err := installAutomatically([]string{"alpine-only", "veyra-only", "nix-only"}); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	got := strings.Split(strings.TrimSpace(string(data)), "\n")
	want := []string{
		"apk update  repositories=https://dl-cdn.alpinelinux.org/alpine/v3.22/main,",
		"search alpine-only repositories=https://dl-cdn.alpinelinux.org/alpine/v3.22/main,",
		"search veyra-only repositories=https://dl-cdn.alpinelinux.org/alpine/v3.22/main,",
		"search nix-only repositories=https://dl-cdn.alpinelinux.org/alpine/v3.22/main,",
		"apk update  repositories=https://dl-cdn.alpinelinux.org/alpine/v3.22/main,@veyra https://packages.veyra.example/veyra-pkgrepo,",
		"search veyra-only repositories=https://packages.veyra.example/veyra-pkgrepo,",
		"search nix-only repositories=https://packages.veyra.example/veyra-pkgrepo,",
		"apk add alpine-only veyra-only@veyra repositories=https://dl-cdn.alpinelinux.org/alpine/v3.22/main,@veyra https://packages.veyra.example/veyra-pkgrepo,",
		"nix profile install nixpkgs#nix-only",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("source lookup/installation order mismatch\n got: %#v\nwant: %#v", got, want)
	}
}

func TestMissingArgs(t *testing.T) {
	useUserEnvironment(t, true)
	if dispatch("install", "alpine", nil) == nil {
		t.Fatal("accepted empty install")
	}
	if dispatch("remove", "nix", nil) == nil {
		t.Fatal("accepted empty remove")
	}
}

func TestBootControlIsNotPartOfVpkg(t *testing.T) {
	useUserEnvironment(t, true)
	for _, action := range []string{"deployments", "activate", "rollback"} {
		if err := dispatch(action, "apk", []string{"A"}); err == nil || !strings.Contains(err.Error(), "unsupported command") {
			t.Fatalf("vpkg accepted boot-control action %s: %v", action, err)
		}
	}
}
