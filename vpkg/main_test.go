package main

import (
 "os"
 "path/filepath"
 "strings"
 "testing"
)

func TestParse(t *testing.T) {
 s,p,e:=parse([]string{"firefox","--from","nix"})
 if e!=nil||s!="nix"||len(p)!=1||p[0]!="firefox" {t.Fatalf("parse: %s %v %v",s,p,e)}
 for _,bad:=range [][]string{{"--from","invalid"},{"--bad"},{"--from"}} {
  if _,_,e:=parse(bad);e==nil {t.Fatalf("accepted %v",bad)}
 }
}

func TestDispatch(t *testing.T) {
 dir:=t.TempDir()
 log:=filepath.Join(dir,"commands")
 for _,name:=range []string{"apk","nix"} {
  script:="#!/bin/sh\nprintf '%s\\n' \""+name+" $*\" >> \"$VPKG_TEST_LOG\"\n"
  if e:=os.WriteFile(filepath.Join(dir,name),[]byte(script),0755);e!=nil {t.Fatal(e)}
 }
 t.Setenv("PATH",dir+":"+os.Getenv("PATH"))
 t.Setenv("VPKG_TEST_LOG",log)
 for _,tc:=range []struct{cmd,source string;args []string}{
  {"install","alpine",[]string{"firefox"}},
  {"upgrade","alpine",nil},
  {"install","nix",[]string{"helix"}},
  {"upgrade","nix",nil},
 } {
  if e:=dispatch(tc.cmd,tc.source,tc.args);e!=nil {t.Fatal(e)}
 }
 b,e:=os.ReadFile(log);if e!=nil {t.Fatal(e)}
 for _,want:=range []string{"apk add firefox","apk upgrade","nix profile install nixpkgs#helix","nix profile upgrade --all"} {
  if !strings.Contains(string(b),want) {t.Fatalf("missing %q: %s",want,b)}
 }
}

func TestMissingArgs(t *testing.T) {
 if dispatch("install","alpine",nil)==nil {t.Fatal("accepted empty install")}
 if dispatch("remove","nix",nil)==nil {t.Fatal("accepted empty remove")}
}

func TestAtomicBootCommands(t *testing.T) {
 oldMarker,oldBinary,oldStore:=markerFile,bootCtlBinary,bootCtlStore
 defer func(){markerFile,bootCtlBinary,bootCtlStore=oldMarker,oldBinary,oldStore}()
 dir:=t.TempDir()
 markerFile=filepath.Join(dir,"deployment-mode")
 if err:=os.WriteFile(markerFile,[]byte("atomic-v1\n"),0644);err!=nil{t.Fatal(err)}
 log:=filepath.Join(dir,"boot-log")
 bootCtlBinary=filepath.Join(dir,"veyra-bootctl")
 bootCtlStore="/var/lib/veyra/store"
 script:="#!/bin/sh\nprintf '%s\n' \"$*\" >> \"$VPKG_TEST_LOG\"\n"
 if err:=os.WriteFile(bootCtlBinary,[]byte(script),0755);err!=nil{t.Fatal(err)}
 t.Setenv("VPKG_TEST_LOG",log)
 if err:=dispatch("deployments","alpine",nil);err!=nil{t.Fatal(err)}
 if err:=dispatch("activate","alpine",[]string{"B"});err!=nil{t.Fatal(err)}
 if err:=dispatch("rollback","alpine",[]string{"A"});err!=nil{t.Fatal(err)}
 b,err:=os.ReadFile(log);if err!=nil{t.Fatal(err)}
 for _,expected:=range []string{"--store /var/lib/veyra/store status","--store /var/lib/veyra/store activate B","--store /var/lib/veyra/store rollback A"}{
  if !strings.Contains(string(b),expected){t.Fatalf("expected %q in %s",expected,string(b))}
 }
 if err:=dispatch("upgrade","alpine",nil);err==nil{t.Fatal("atomic mode allowed in-place upgrade")}
 if err:=dispatch("activate","alpine",nil);err==nil{t.Fatal("accepted empty ID")}
 if err:=dispatch("rollback","alpine",[]string{"A","B"});err==nil{t.Fatal("accepted multiple IDs")}
}
