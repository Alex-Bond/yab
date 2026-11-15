// Authored source guards only until an explicit farm run records their result.
import test from "node:test";
import assert from "node:assert/strict";
import { SiteDataType, SUPPORTED_SITE_TYPES, siteScope, sameSiteOwner, supportsSiteTypes } from "../runtime/YabScopedSitePolicy.sys.mjs";

const request = { host: "example.test", contextId: "gvctx6163636f756e74", privateMode: false, types: 7 };
const attributes = { geckoViewSessionContextId: request.contextId, privateBrowsingId: 0, userContextId: 0 };

test("full iOS request and unknown upper bits are refused before side effects", () => {
  assert.equal(SUPPORTED_SITE_TYPES, 7);
  for (const types of [SiteDataType.ALL, 8, 32, 64, 128, 256, 4294967303, 0, -1, NaN, 1.5, "7"]) {
    assert.equal(supportsSiteTypes(types), false);
    assert.throws(() => siteScope({ ...request, types }), /UNSUPPORTED_DATA_TYPES/);
  }
});

test("URI-like, wildcard, case alias and malformed hosts are never interpreted as a scope", () => {
  for (const host of ["", ".example.test", "*.example.test", "example.test/", "https://example.test", "example.test:443",
    "example.test?token=x", "EXAMPLE.test", "éxample.test", "[::1]", "example..test", "-bad.test", "bad-.test"]) {
    assert.throws(() => siteScope({ ...request, host }), /INVALID_HOST/);
  }
});

test("explicit context and exact Boolean private provenance are mandatory", () => {
  for (const contextId of [null, "", "default", "gvctx", "gvctxempty", "gvctxXYZ", "gvctx/../../foreign"]) {
    assert.throws(() => siteScope({ ...request, contextId }), /INVALID_CONTEXT/);
  }
  for (const privateMode of [0, 1, "false", null, undefined]) {
    assert.throws(() => siteScope({ ...request, privateMode }), /INVALID_CONTEXT/);
  }
});

test("a context lease is immutable and never expands to parent or neighbor hosts", () => {
  const scope = siteScope(request);
  assert.equal(Object.isFrozen(scope), true);
  assert.equal(sameSiteOwner(scope, request.host, attributes), true);
  for (const host of ["neighbor.test", "sub.example.test", "test", "example.test.evil", "EXAMPLE.test"]) {
    assert.equal(sameSiteOwner(scope, host, attributes), false);
  }
});

test("public A cannot touch public B or any Private origin", () => {
  const scope = siteScope(request);
  for (const changed of [{ geckoViewSessionContextId: "gvctx62" }, { privateBrowsingId: 1 }, { userContextId: 3 }]) {
    assert.equal(sameSiteOwner(scope, request.host, { ...attributes, ...changed }), false);
  }
});

test("Private requires the matching exact private bit even for the same native context string", () => {
  const scope = siteScope({ ...request, privateMode: true });
  assert.equal(sameSiteOwner(scope, request.host, attributes), false);
  assert.equal(sameSiteOwner(scope, request.host, { ...attributes, privateBrowsingId: 1 }), true);
});

test("missing/default origin attributes are not wildcard permission", () => {
  const scope = siteScope(request);
  for (const values of [null, {}, { ...attributes, userContextId: undefined }, { ...attributes, privateBrowsingId: undefined }]) {
    assert.equal(sameSiteOwner(scope, request.host, values), false);
  }
});

test("partition variants keep their native descriptor while staying inside host and account context", () => {
  const scope = siteScope(request);
  assert.equal(sameSiteOwner(scope, request.host, { ...attributes, partitionKey: "(https,top.test)" }), true);
  assert.equal(sameSiteOwner(scope, "third-party.test", { ...attributes, partitionKey: "(https,example.test)" }), false);
});
