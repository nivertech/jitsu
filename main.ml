(*
 * Copyright (c) 2014 Magnus Skjegstad <magnus@skjegstad.com>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Str
open Dns
open Lwt
open Lwt_list
open Libvirt
open Jitsu
open Cmdliner

let info =
    let doc = "Just-In-Time Summoning of Unikernels. Jitsu is a forwarding DNS server that automatically starts unikernel VMs when their domain is requested. The DNS response is sent to the client after the unikernel has started, enabling the client to use unmodified software to communicate with unikernels that are started on demand. If no DNS requests are received for the unikernel within a given timeout period, the VM is automatically stopped." in
    let man = [ 
        `S "EXAMPLES"; 
        `P "jitsu -c xen:/// -f 8.8.8.8 -m destroy mirage.org,10.0.0.1,mirage-www"; 
        `P "Connect to Xen. Start VM 'mirage-www' on requests for mirage.org and return IP 10.0.0.1 when VM is running. Forward unknown requests to 8.8.8.8 (Google). Expired VMs are destroyed."; 
        `P "jitsu -c vbox:///session -m suspend home.local,192.168.0.1,ubuntu -t 60";
        `P "Connect to Virtualbox. Start VM 'ubuntu' on requests for home.local and return IP 192.168.0.1. Forward unknown requests to system default. Expired VMs are suspended after 120 seconds (2 x DNS ttl).";
        `S "AUTHORS"; 
        `P "Magnus Skjegstad <magnus@skjegstad.com>" ; 
        `S "BUGS"; 
        `P "Submit bug reports to http://github.com/magnuss/jitsu";] in
    Term.info "jitsu" ~version:"0.1-alpha" ~doc ~man

let bindaddr =
    let doc = "Bind local DNS server to interface with this IP" in
    Arg.(value & opt string "127.0.0.1" & info ["b"; "bind"] ~docv:"ADDR" ~doc)

let bindport = 
    let doc = "UDP port to listen for DNS queries" in
    Arg.(value & opt int 53 & info ["l"; "listen"] ~docv:"PORT" ~doc)

let connstr = 
    let doc = "libvirt connection string (e.g. xen+ssh://x.x.x.x/system or vbox:///session)" in
    Arg.(value & opt string "xen:///" & info ["c"; "connect"] ~docv:"CONNECT" ~doc)

let forwarder =
    let doc = "IP address of DNS server queries should be forwarded to if no local match is found. Defaults to system default (/etc/resolv.conf) if not specified." in
    Arg.(value & opt string "" & info ["f" ; "forwarder"] ~docv:"ADDR" ~doc)

let forwardport = 
    let doc = "UDP port to forward DNS queries to" in
    Arg.(value & opt int 53 & info ["p"; "port"] ~docv:"PORT" ~doc)

let response_delay =
    let doc = "Time to wait in seconds before responding to a DNS query after the local VM has started. This delay gives the VM time to open up the necessary TCP ports etc. Setting this value too low can result in long delays on the first TCP request to the VM." in
    Arg.(value & opt float 0.1 & info ["d" ; "delay" ] ~docv:"SECONDS" ~doc)

let map_domain =
    let doc = "Maps DOMAIN to a VM and IP. VM must match a VM available through libvirt (see virsh list --all)." in
    Arg.(non_empty & pos_all (t3 ~sep:',' string string string) [] & info [] ~docv:"DOMAIN,IP,VM" ~doc)

let ttl =
    let doc = "DNS TTL in seconds. The TTL determines how long the clients may cache our DNS response. VMs are terminated after no DNS requests have been received for TTL*2 seconds." in
    Arg.(value & opt int 60 & info ["t" ; "ttl" ] ~docv:"SECONDS" ~doc)

let vm_stop_mode =
    let doc = "How to stop running VMs after timeout. Valid options are $(b,suspend), $(b,destroy) and $(b,shutdown). Suspended VMs are generally faster to resume, but require resources to store state. Note that Mirage suspend/resume is currently not supported on ARM." in
    Arg.(value & opt (enum [("destroy", Jitsu.VmStopDestroy); ("suspend", Jitsu.VmStopSuspend); ("shutdown", Jitsu.VmStopShutdown)]) Jitsu.VmStopSuspend & info ["m" ; "mode" ] ~docv:"MODE" ~doc)

let jitsu connstr bindaddr bindport forwarder forwardport response_delay map_domain ttl vm_stop_mode =
    let rec maintenance_thread t timeout = 
        Lwt_unix.sleep timeout 
        >>= fun () ->
        Lwt_io.printf "."
        >>= fun () ->
        Jitsu.stop_expired_vms t
        >>= fun () ->
        maintenance_thread t timeout in
    Lwt_main.run (
            ((match forwarder with
                | "" -> Dns_resolver_unix.create () (* use resolv.conf *)
                | _  -> let forwardip = Ipaddr.of_string_exn forwarder in (* use ip from forwarder *)
                        let servers = [(forwardip,forwardport)] in 
                        let config = `Static ( servers , [""] ) in 
                        Dns_resolver_unix.create ~config:config ()
            )
            >>= fun forward_resolver ->
            Lwt_io.printf "Connecting to %s...\n" connstr 
            >>= fun () ->
            Jitsu.create connstr forward_resolver (List.length map_domain) ttl
            >>= fun t ->
            Lwt.choose [(
                (* main thread, DNS server *)
                let triple (dns,ip,name) = 
                    Lwt_io.printf "Adding domain '%s' for VM '%s' with ip %s\n" dns name ip
                    >>= fun() ->
                    Jitsu.add_vm t dns name (Ipaddr.V4.of_string_exn ip) vm_stop_mode response_delay ttl  in
                Lwt_list.iter_p triple map_domain
                >>= fun () ->
                Lwt_io.printf "Starting server on %s:%d...\n" bindaddr bindport
                >>= fun () ->
                let processor = ((Dns_server.processor_of_process (Jitsu.process t)) :> (module Dns_server.PROCESSOR)) in 
                Dns_server_unix.serve_with_processor ~address:bindaddr ~port:bindport ~processor);
                (* maintenance thread, delay in seconds *)
                (maintenance_thread t 5.0)]);
         )

let jitsu_t = 
    Term.(pure jitsu $ connstr $ bindaddr $ bindport $ forwarder $ forwardport $ response_delay $ map_domain $ ttl $ vm_stop_mode )

let () = 
    match Term.eval (jitsu_t, info) with 
    | `Error _ -> exit 1 
    | _ -> exit 0

