package main

import (
	"reflect"
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
	var got [][]string
	oldRunner := commandRunner
	commandRunner = func(name string, args ...string) error {
		got = append(got, append([]string{name}, args...))
		return nil
	}
	t.Cleanup(func() { commandRunner = oldRunner })
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
	want := [][]string{
		{"apk", "add", "firefox"},
		{"apk", "upgrade"},
		{"nix", "profile", "install", "nixpkgs#helix"},
		{"nix", "profile", "upgrade", "--all"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("commands = %#v, want %#v", got, want)
	}
}

func TestMissingArgs(t *testing.T) {
	if dispatch("install", "alpine", nil) == nil {
		t.Fatal("accepted empty install")
	}
	if dispatch("remove", "nix", nil) == nil {
		t.Fatal("accepted empty remove")
	}
}
