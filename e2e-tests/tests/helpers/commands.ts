export function customPredicateString(
    elementType: string,
    attribute: string,
    value: string,
    comparisonOperator: string,
  ) {
    const predicateString: string = `-ios predicate string:elementType == ${elementType} AND ${attribute} ${comparisonOperator} '${value}'`
    return predicateString
  }
  
  export function getPredicateForTextValueEqual(value: string) {
    const predicateString: string = `-ios predicate string:elementType == 48 AND value == '${value}'`
    return predicateString
  }
  