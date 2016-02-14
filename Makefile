
OCB_FLAGS = -tag bin_annot -use-ocamlfind -tag thread -I common
OCB = ocamlbuild $(OCB_FLAGS)

condo:
	$(OCB) -I condo condo.byte

condo_native:
	$(OCB) -I condo condo.native

monitoring:
	$(OCB) -I monitoring condo_monitoring.byte

monitoring_native:
	$(OCB) -I monitoring condo_monitoring.native

.PHONY: condo condo_native monitoring monitoring_native
