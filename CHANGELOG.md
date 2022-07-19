# Changelog

## Unreleased

## 0.7.1 (July 19th, 2022)

* Queries for non unique keys - [#114](https://github.com/Gravity-Core/graphism/pull/114)
* Simplified auth on has_many relations - [#113](https://github.com/Gravity-Core/graphism/pull/113)

## 0.7.0 (July 19th, 2022)

* Split code into smaller modules - [#111](https://github.com/Gravity-Core/graphism/pull/111) 
* Fix index creation order - [#110](https://github.com/Gravity-Core/graphism/pull/110)
* Custom aggregations - [#109](https://github.com/Gravity-Core/graphism/pull/109)
* Relation telemetry - [#108](https://github.com/Gravity-Core/graphism/pull/108)
* Authorization telemetry - [#107](https://github.com/Gravity-Core/graphism/pull/107)
* Custom queries - [#105](https://github.com/Gravity-Core/graphism/pull/105)
* Optional entity refetch - [#104](https://github.com/Gravity-Core/graphism/pull/104)
* Manual preloads - [#103](https://github.com/Gravity-Core/graphism/pull/103)

## 0.6.0 (June 24th, 2022)

* Scope list results - [#101](https://github.com/Gravity-Core/graphism/pull/101)
* Json type - [#100](https://github.com/Gravity-Core/graphism/pull/100)
* Improved schema Introspection - [#99](https://github.com/Gravity-Core/graphism/pull/99)

## 0.5.1 (June 14th, 2022)

* Fix support for `:text` attributes - [#98](https://github.com/Gravity-Core/graphism/pull/98)

## 0.5.0 (June 13th, 2022)

* Add `:text` attribute type - [#97](https://github.com/Gravity-Core/graphism/pull/97)
* Introspection enhancements
  * Add `column_type/1` to entity schema mmodule - [#94](https://github.com/Gravity-Core/graphism/pull/94)
  * Add `column_name/1` to entity schema module - [#96](https://github.com/Gravity-Core/graphism/pull/96)

## 0.4.4 (May 5th, 2022)

* Pass parent structs to before hooks - [#92](https://github.com/Gravity-Core/graphism/pull/92)
* Cascade deletes - [#91](https://github.com/Gravity-Core/graphism/pull/91)
* Better migrations - [#90](https://github.com/Gravity-Core/graphism/pull/90)
* More accurate primary keys in relations with aliases - [#89](https://github.com/Gravity-Core/graphism/pull/89)

## 0.4.3 (April 26th, 2022)

* More flexible query pagination - [#87](https://github.com/Gravity-Core/graphism/pull/87)

## 0.4.2 (April 25th, 2022)

* Fix query pagination and preloads - [#86](https://github.com/Gravity-Core/graphism/pull/86)

## 0.4.1 (April 22th, 2022)

* Aggregate queries - [#84](https://github.com/Gravity-Core/graphism/pull/84)
* Use aggregateAll instead of aggregate - [#85](https://github.com/Gravity-Core/graphism/pull/85)

## 0.4.0 (April 15th, 2022)

* Sorting and paginating queries - [#82](https://github.com/Gravity-Core/graphism/pull/82)

## 0.3.10 (April 2nd, 2022)

* Skippable migrations - [#80](https://github.com/Gravity-Core/graphism/pull/80)

## 0.3.9 (March 17th, 2022)

* Field validation improvements - [#77](https://github.com/Gravity-Core/graphism/pull/77)

## 0.3.8 (March 8th, 2022)

* Non empty fields - [#75](https://github.com/Gravity-Core/graphism/pull/75)

## 0.3.7 (March 7th, 2022)

* Immutable fields - [#74](https://github.com/Gravity-Core/graphism/pull/74)

## 0.3.6 (Feb 25th, 2022)

* Before/After hooks when deleting - [#72](https://github.com/Gravity-Core/graphism/pull/72)

## 0.3.5 (Feb 20th, 2022)

* More robust migrations parsing - [#69](https://github.com/Gravity-Core/graphism/pull/69)

## 0.3.4 (Feb 13rd, 2022)

* Entity sort - [#67](https://github.com/Gravity-Core/graphism/pull/67)

## 0.3.3 (Feb 1st, 2022)

* Self referencing entities - [#65](https://github.com/Gravity-Core/graphism/pull/65)

## 0.3.2 (Jan 15th, 2022)

* Absinthe middleware - [#63](https://github.com/Gravity-Core/graphism/pull/63)

## 0.3.1 (Jan 7th, 2022)

* Support optional computed attributes - [#61](https://github.com/Gravity-Core/graphism/pull/61)

## 0.3.0 (Dec 28th, 2021)

* File uploads - [#59](https://github.com/Gravity-Core/graphism/pull/59)

## 0.2.2 (Dec 17th, 2021)

* Non unique keys - [#57](https://github.com/Gravity-Core/graphism/pull/57)
* Custom mutations and computed attributes improvements - [#55](https://github.com/Gravity-Core/graphism/pull/55)

## 0.2.1 (Dec 4th, 2021)

* Ability to chain after hooks - [#53](https://github.com/Gravity-Core/graphism/pull/53)

## 0.2.0 (Dec 3rd, 2021)

* Support for dates without time information - [#51](https://github.com/Gravity-Core/graphism/pull/51)
* More flexible entity fetch on api create/update - [#50](https://github.com/Gravity-Core/graphism/pull/50)
* Optional preloads - [#49](https://github.com/Gravity-Core/graphism/pull/49)
* Graceful foreign key constraint validations - [#48](https://github.com/Gravity-Core/graphism/pull/48)
* Composite keys - [#47](https://github.com/Gravity-Core/graphism/pull/47)
* Client generated ids - [#46](https://github.com/Gravity-Core/graphism/pull/46)
* Lookup arguments - [#44](https://github.com/Gravity-Core/graphism/pull/44)
