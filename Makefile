.PHONY: verify release

verify:
	./scripts/verify-consumption.sh

release:
	@test -n "$(TAG)" || (echo "TAG=v<ver>+rewrap.<n> required — e.g. make release TAG=v0.7.3+rewrap.1" >&2; exit 1)
	./scripts/rewrap-xcframework.sh --tag $(TAG)
	$(MAKE) verify
	gh release create $(TAG) \
		--title "$(TAG)" \
		--notes "Rewrapped LiteRTLM xcframework for tag $(TAG). See rewrap-manifest.json for sha256 values." \
		"CLiteRTLM-$(TAG).xcframework.zip" \
		"GemmaModelConstraintProvider-$(TAG).xcframework.zip" \
		rewrap-manifest.json
