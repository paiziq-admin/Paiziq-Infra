TERRAFORM ?= terraform
.PHONY: check
check:
	$(TERRAFORM) fmt -check -recursive
	$(TERRAFORM) init -backend=false -input=false
	$(TERRAFORM) validate
	$(TERRAFORM) test
	python3 -m unittest discover -s tests -v
