package main

import (
 "os"
 "path/filepath"
 "strings"
 "testing"
)

func useTestMode(t *testing.T,mode string){
 t.Helper()
 old:=markerFile
 markerFile=filepath.Join(t.TempDir(),"deployment-mode")
 t.Cleanup(func(){markerFile=old})
 if mode!=""{
  if err:=os.WriteFile(markerFile,[]byte(mode+"\n"),0644);err!=nil{t.Fatal(err)}
 }
}

func TestLegacySystemAllowsOriginalPackageBackend(t *testing.T){
 useTestMode(t,"")
 atomic,err:=atomicSystem()
 if err!=nil||atomic{t.Fatalf("legacy mode unexpectedly atomic: %v",err)}
}

func TestAtomicModeBlocksLiveRootWrites(t *testing.T){
 useTestMode(t,"atomic-v1")
 atomic,err:=atomicSystem()
 if err!=nil||!atomic{t.Fatalf("atomic mode not detected: %v",err)}
 for _,action:=range []string{"install","remove","update","upgrade"}{
  if err:=dispatch(action,"alpine",[]string{"plasma-desktop"});err==nil||
     !strings.Contains(err.Error(),"in-place"){
    t.Fatalf("atomic %s did not reject live-root writes: %v",action,err)
  }
 }
}

func TestAtomicModeRequiresEngineEvenForQueries(t *testing.T){
 useTestMode(t,"atomic-v1")
 dir:=t.TempDir()
 t.Setenv("PATH",dir)
 if err:=dispatch("list","alpine",nil);err==nil{
  t.Fatal("atomic mode used fallback apk without native engine")
 }
}

func TestAtomicModeRejectsUnknownPolicy(t *testing.T){
 useTestMode(t,"unknown")
 if err:=dispatch("update","alpine",nil);err==nil{
  t.Fatal("unknown system mode failed open")
 }
}

func TestNativeEnginePreferred(t *testing.T){
 useTestMode(t,"legacy")
 dir:=t.TempDir()
 log:=filepath.Join(dir,"log")
 t.Setenv("VPKG_TEST_LOG",log)
 for _,name:=range []string{"apk","vpkg-engine"}{
  script:="#!/bin/sh\nprintf '%s\\n' '"+name+" $*' >> \"$VPKG_TEST_LOG\"\n"
  if err:=os.WriteFile(filepath.Join(dir,name),[]byte(script),0755);err!=nil{t.Fatal(err)}
 }
 t.Setenv("PATH",dir+":"+os.Getenv("PATH"))
 if err:=dispatch("search","alpine",[]string{"plasma"});err!=nil{t.Fatal(err)}
 data,err:=os.ReadFile(log);if err!=nil{t.Fatal(err)}
 if string(data)!="vpkg-engine search plasma\n"{
  t.Fatalf("did not use native fork: %q",data)
 }
}
