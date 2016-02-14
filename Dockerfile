FROM prepor/ocaml:4.02.3

RUN apt-get update && apt-get install -y build-essential git pkg-config

ADD opam.switch /opam.switch

RUN eval `opam config env` && \
    opam update && \
    opam pin add edn https://github.com/prepor/ocaml-edn.git && \
    opam switch import /opam.switch

ADD . /opt/condo
WORKDIR /opt/condo

CMD bash -c 'eval `opam config env` && make condo_native monitoring_native'
