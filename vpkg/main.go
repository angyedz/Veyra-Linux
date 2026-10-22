// vpkg: Veyra frontend. Atomic hosts must never modify their active root.
package main

import (
 "errors"
 "fmt"
 "os"
 "os/exec"
 "strings"
)

const version = "0.2.0-dev"

func usage() {
 fmt.Print(`vpkg `+version+` - Veyra package manager

Usage:
  vpkg install <package>... [--from apk|nix]
  vpkg remove <package>...  [--from apk|nix]
  vpkg search <term>        [--from apk|nix]
  vpkg info <package>       [--from apk|nix]
  vpkg list                 [--from apk|nix]
  vpkg update
  vpkg upgrade              [--from apk|nix]
  vpkg version
  vpkg help

Default source: APK, using every configured APK repository (including Alpine and
veyra-pkgrepo). Nix commands affect the current user's profile.
`)
}

func parse(args []string) (string, []string, error) {
 source:="apk"
 var rest []string
 for i:=0;i<len(args);i++ {
  switch {
  case args[i]=="--from":
   if i+1>=len(args) {return "",nil,fmt.Errorf("--from requires apk or nix")}
   source=args[i+1];i++
  case strings.HasPrefix(args[i],"--from="):
   source=strings.TrimPrefix(args[i],"--from=")
  case strings.HasPrefix(args[i],"-"):
   return "",nil,fmt.Errorf("unknown option: %s",args[i])
  default:rest=append(rest,args[i])
  }
 }
 // Keep the former name as an alias for scripts already using it. The APK
 // backend searches all configured APK repositories, not just Alpine's.
 if source=="alpine" {source="apk"}
 if source!="apk"&&source!="nix" {return "",nil,fmt.Errorf("unsupported source %q",source)}
 return source,rest,nil
}

func run(name string,args ...string) error {
 cmd:=exec.Command(name,args...)
 cmd.Stdin=os.Stdin;cmd.Stdout=os.Stdout;cmd.Stderr=os.Stderr
 if err:=cmd.Run();err!=nil{return fmt.Errorf("%s: %w",name,err)}
 return nil
}

// Atomic mode is fail-closed; missing marker denotes a conventional Live ISO
// or an existing non-atomic Alpine-based Veyra installation.
var markerFile = "/etc/veyra/deployment-mode"
var bootCtlBinary = "/usr/local/sbin/veyra-bootctl"
var bootCtlStore = "/var/lib/veyra/store"

func atomicSystem()(bool,error){
 data,err:=os.ReadFile(markerFile)
 if errors.Is(err,os.ErrNotExist){return false,nil}
 if err!=nil{return false,fmt.Errorf("cannot read Veyra system policy: %w",err)}
 switch strings.TrimSpace(string(data)){
 case "legacy":return false,nil
 case "atomic-v1":return true,nil
 default:return false,fmt.Errorf("unknown Veyra system mode: %q",strings.TrimSpace(string(data)))
 }
}

func systemEngine()string{
 if _,err:=exec.LookPath("vpkg-engine");err==nil{return "vpkg-engine"}
 return "apk" // Live ISO/legacy installations only
}

func dispatch(action,source string,packages []string) error {
 if source=="alpine" {source="apk"}
 need:=func()error{if len(packages)==0{return fmt.Errorf("%s requires a package name",action)};return nil}
 if source=="apk" {
  atomic,err:=atomicSystem()
  if err!=nil{return err}
  if action=="deployments"||action=="activate"||action=="rollback"{
   if !atomic{return fmt.Errorf("%s requires an atomic Veyra installation",action)}
   if action=="deployments"{
    if len(packages)!=0{return fmt.Errorf("deployments takes no arguments")}
    return run(bootCtlBinary,"--store",bootCtlStore,"status")
   }
   if len(packages)!=1{return fmt.Errorf("%s requires exactly one deployment ID",action)}
   return run(bootCtlBinary,"--store",bootCtlStore,action,packages[0])
  }
  switch action {
  case "install","remove","update","upgrade":
   if atomic{return fmt.Errorf("atomic Veyra forbids in-place system changes; update an inactive deployment instead")}
  }
  engine:=systemEngine()
  if atomic&&engine=="apk"{return fmt.Errorf("atomic Veyra requires native vpkg-engine; upstream APK fallback is forbidden")}
  switch action {
  case "install":if e:=need();e!=nil{return e};return run(engine,append([]string{"add"},packages...)...)
  case "remove":if e:=need();e!=nil{return e};return run(engine,append([]string{"del"},packages...)...)
  case "search":if e:=need();e!=nil{return e};return run(engine,append([]string{"search"},packages...)...)
  case "info":if e:=need();e!=nil{return e};return run(engine,append([]string{"info","-a"},packages...)...)
  case "list":return run(engine,"info")
  case "update":return run(engine,"update")
  case "upgrade":return run(engine,"upgrade")
  }
 } else {
  switch action {
  case "install":
   if e:=need();e!=nil{return e}
   for _,p:=range packages {if e:=run("nix","profile","install","nixpkgs#"+p);e!=nil{return e}}
   return nil
  case "remove":if e:=need();e!=nil{return e};return run("nix",append([]string{"profile","remove"},packages...)...)
  case "search","info":if e:=need();e!=nil{return e};return run("nix",append([]string{"search","nixpkgs"},packages...)...)
  case "list":return run("nix","profile","list")
  case "upgrade":return run("nix","profile","upgrade","--all")
  }
 }
 return fmt.Errorf("unsupported command %q for %s",action,source)
}

func main() {
 if len(os.Args)<2 {usage();os.Exit(2)}
 action:=os.Args[1]
 if action=="help"||action=="--help"||action=="-h" {usage();return}
 if action=="version"||action=="--version" {fmt.Println("vpkg",version);return}
 source,packages,err:=parse(os.Args[2:])
 if err==nil {err=dispatch(action,source,packages)}
 if err!=nil {fmt.Fprintln(os.Stderr,"vpkg:",err);os.Exit(1)}
}
