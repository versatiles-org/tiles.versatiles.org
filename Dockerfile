FROM jonasal/nginx-certbot:latest

COPY root/ /

RUN sh /versatiles/scripts/install.sh

VOLUME [ "/versatiles" ]

CMD [ "sh", "/versatiles/scripts/run.sh" ]
