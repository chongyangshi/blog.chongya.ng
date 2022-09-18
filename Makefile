.PHONY: docker-build
ALPINE_VERSION := 3.15
SVC := web-blog-chongya-ng
COMMIT := $(shell git log -1 --pretty='%h')

PELICAN=pelican
PELICANOPTS=

BASEDIR=$(PWD)
INPUTDIR=$(BASEDIR)/content
OUTPUTDIR=$(BASEDIR)/output
CONFFILE=$(BASEDIR)/pelicanconf.py
PUBLISHCONF=$(BASEDIR)/publishconf.py

html: clean $(OUTPUTDIR)/index.html
	@echo 'Done'

$(OUTPUTDIR)/%.html:
	$(PELICAN) $(INPUTDIR) -o $(OUTPUTDIR) -s $(CONFFILE) $(PELICANOPTS)

clean:
	find $(OUTPUTDIR) -mindepth 1 -delete

regenerate: clean
	$(PELICAN) -r $(INPUTDIR) -o $(OUTPUTDIR) -s $(CONFFILE) $(PELICANOPTS)

publish:
	$(PELICAN) $(INPUTDIR) -o $(OUTPUTDIR) -s $(PUBLISHCONF) $(PELICANOPTS)

hack:
	echo '\n\narticle img { width: 100%; } \n' >> $(BASEDIR)/output/theme/css/main.css	
	rm $(BASEDIR)/output/theme/css/pygment.css

docker-build: publish hack
	docker buildx build --platform linux/amd64 -t ${SVC} --build-arg ALPINE_VERSION=${ALPINE_VERSION} . 

docker-pull:
	docker pull alpine:${ALPINE_VERSION}

docker-push:
	docker tag ${SVC}:latest icydoge/web:${SVC}-${COMMIT}
	docker push icydoge/web:${SVC}-${COMMIT}

all: docker-pull docker-build docker-push

.PHONY: html clean regenerate publish docker-pull docker-build docker-push all
