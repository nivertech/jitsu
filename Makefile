PACKAGES=-package str,lwt,dns.lwt,libvirt,cmdliner
INCLUDE=
OPT=-linkpkg -g 

all: jitsu

jitsu: jitsu.ml main.ml
	ocamlfind ocamlopt $(INCLUDE) $(PACKAGES) $(OPT) jitsu.ml  main.ml -o jitsu

clean:
	rm -f jitsu jitsu.cmx jitsu.cmi jitsu.o main.o main.cmx main.cmi
	rm -f *~ tags
