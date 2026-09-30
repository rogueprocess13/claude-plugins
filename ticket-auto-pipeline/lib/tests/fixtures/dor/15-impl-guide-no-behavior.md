## Summary

Migrate the billing service's ORM from the legacy query builder to the new repository layer.

## Background / Motivation

The legacy query builder is deprecated upstream and blocks us from picking up security patches on the database driver.

## Proposed Behaviour

Every billing-svc data access path goes through the new repository layer instead of the legacy query builder.

## Acceptance Criteria

- [ ] Create `InvoiceRepository`, `PayoutRepository`, and `CustomerRepository` classes
- [ ] Migrate `InvoiceController` to use `InvoiceRepository`
- [ ] Migrate `PayoutJob` to use `PayoutRepository`
- [ ] Migrate `CustomerController` to use `CustomerRepository`
- [ ] Update `package.json` to drop the legacy query builder dependency
- [ ] Update the internal wiki page describing the data access layer

## Scope

| Layer | Service     | Area         |
| ----- | ----------- | ------------ |
| BE    | billing-svc | data-access  |

## Related Tickets

None
