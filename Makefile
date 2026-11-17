# Rebuild and check slim images for the homelab stacks (see slim-image.sh).
#
#   make slim P=somafm     pull the source image, rebuild the slim image,
#                          then compare it with the source image
#   make verify P=somafm   compare again without rebuilding
#   make sizes P=somafm    show both image sizes
#   make list              list the profiles
#
# After "make slim" passes, recreate the stack from its own folder
# (make force) so the container picks up the new slim image.

.DEFAULT_GOAL := default

slim:
	@test -n "$(P)" || { echo "Set P=<profile>, see: make list"; exit 2; }
	./slim-image.sh build "$(P)"
	./slim-image.sh verify "$(P)"

verify:
	@test -n "$(P)" || { echo "Set P=<profile>, see: make list"; exit 2; }
	./slim-image.sh verify "$(P)"

sizes:
	@test -n "$(P)" || { echo "Set P=<profile>, see: make list"; exit 2; }
	./slim-image.sh sizes "$(P)"

list:
	@./slim-image.sh list

default:
	@echo " "
	@echo "make slim P=<profile>   - rebuild a slim image and compare it with the source"
	@echo "make verify P=<profile> - compare the slim and source images again"
	@echo "make sizes P=<profile>  - show both image sizes"
	@echo "make list               - list the profiles"

.PHONY: slim verify sizes list default
