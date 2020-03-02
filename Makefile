SHELL := /usr/bin/env bash
VENV ?= ./.aws-lambda-sensu-handlers-env
DOCKER_OK := $(shell type -P docker)
OPENSSL_OK := $(shell type -P openssl)
PYTHON_OK := $(shell type -P python)
PYTHON_VERSION := $(shell python -V | cut -d' ' -f2)
PYTHON_REQUIRED := $(shell cat .python-version)
BUCKET_NAME := mdtp-lambda-functions
LAMBDA_NAME := aws-lambda-sensu-handlers
ENVIRONMENTS := integration development qa staging management externaltest production
LAMBDA_VERSION := $(shell test -e .release-version && cat .release-version)
LATEST_TAG := $(shell git tag --sort=v:refname \
	| grep -E "^v[0-9]+\.[0-9]+\.[0-9]+" | tail -1 )
TAG_MAJOR_NUMBER := $(shell echo $(LATEST_TAG) | cut -f 1 -d '.' )
TAG_RELEASE_NUMBER := $(shell echo $(LATEST_TAG) | cut -f 2 -d '.' )
TAG_PATCH_NUMBER := $(shell echo $(LATEST_TAG) | cut -f 3 -d '.' )

check_docker:
	@echo '********** Checking for docker installation *********'
    ifeq ('$(DOCKER_OK)','')
	    $(error package 'docker' not found!)
    else
	    @echo Found docker!
    endif

check_openssl:
	@echo '********** Checking for openssl installation *********'
    ifeq ('$(OPENSSL_OK)','')
	    $(error package 'openssl' not found!)
    else
	    @echo Found openssl!
    endif

check_python:
	@echo '*********** Checking for Python installation ***********'
    ifeq ('$(PYTHON_OK)','')
	    $(error python interpreter: 'python' not found!)
    else
	    @echo Found Python
    endif
	@echo '*********** Checking for Python version ***********'
    ifneq ('$(PYTHON_REQUIRED)','$(PYTHON_VERSION)')
	    $(error incorrect version of python found: '${PYTHON_VERSION}'. Expected '${PYTHON_REQUIRED}'!)
    else
	    @echo Found Python ${PYTHON_REQUIRED}
    endif

setup: check_python
	@echo '**************** Creating virtualenv *******************'
	python -m venv $(VENV)
	${VENV}/bin/pip install --upgrade pip
	${VENV}/bin/pip install -r requirements/requirements-local.txt
	${VENV}/bin/pip install mypy
	@echo '*************** Installation Complete ******************'

setup_git_hooks:
	@echo '****** Setting up git hooks ******'
	${VENV}/bin/pre-commit install

install: setup setup_git_hooks

typechecking: check_python
	${VENV}/bin/mypy ./sensu_handlers

black: check_python
	${VENV}/bin/black ./sensu_handlers

security_checks:
	${VENV}/bin/safety check
	${VENV}/bin/bandit -r ./sensu_handlers --skip B303 --exclude ./sensu_handlers/test_sensu_handlers.py

test: check_python typechecking
	find . -type f -name '*.pyc' -delete
	${VENV}/bin/pytest ./sensu_handlers

clean:
	rm -rf ${VENV}

package: check_openssl
	cd sensu_handlers && zip ../${LAMBDA_NAME}.${LAMBDA_VERSION}.zip ./sensu_handlers.py
	mkdir -p pip_lambda_packages
	pip install -t pip_lambda_packages -r requirements/requirements.txt
	cd pip_lambda_packages && zip -r ../${LAMBDA_NAME}.${LAMBDA_VERSION}.zip .
	openssl dgst -sha256 -binary ${LAMBDA_NAME}.${LAMBDA_VERSION}.zip | openssl enc -base64 > ${LAMBDA_NAME}.${LAMBDA_VERSION}.zip.base64sha256
	rm -rf pip_lambda_packages

publish:
	for env in ${ENVIRONMENTS}; do \
		aws s3 cp ${LAMBDA_NAME}.${LAMBDA_VERSION}.zip s3://${BUCKET_NAME}-$${env}/${LAMBDA_NAME}/${LAMBDA_NAME}.${LAMBDA_VERSION}.zip --acl=bucket-owner-full-control ;\
		aws s3 cp ${LAMBDA_NAME}.${LAMBDA_VERSION}.zip.base64sha256 s3://${BUCKET_NAME}-$${env}/${LAMBDA_NAME}/${LAMBDA_NAME}.${LAMBDA_VERSION}.zip.base64sha256 --content-type text/plain --acl=bucket-owner-full-control ;\
	done

ci_docker_build: check_docker
	docker build -t python-build-env -f Dockerfile.jenkins .

ci_setup: check_docker
	docker run --user `id -u`:`id -g` -v `pwd`:/src --workdir /src python-build-env make clean setup

ci_test: check_docker
	docker run --user `id -u`:`id -g` -v `pwd`:/src --workdir /src python-build-env make test

ci_security_checks:
	docker run --user `id -u`:`id -g` -v `pwd`:/src --workdir /src python-build-env make security_checks

ci_package: check_docker
	docker run --user `id -u`:`id -g` -v `pwd`:/src --workdir /src python-build-env make package

ci_publish: publish

ci_bumpversion:
	echo "$(TAG_MAJOR_NUMBER).$(TAG_RELEASE_NUMBER).$$(( $(TAG_PATCH_NUMBER) + 1))" > .release-version

ci: ci_docker_build ci_setup ci_test ci_security_checks ci_bumpversion ci_package ci_publish