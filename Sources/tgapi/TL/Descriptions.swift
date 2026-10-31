import Foundation

final class ConstructorParameterDescription {
    let value: Optional<Any>

    init(_ value: Optional<Any>) {
        self.value = value
    }
}

final class FunctionDescription {
    let name: String
    let parameters: [(String, ConstructorParameterDescription)]

    init(name: String, parameters: [(String, ConstructorParameterDescription)]) {
        self.name = name
        self.parameters = parameters
    }
}

protocol TypeConstructorDescription {
    func descriptionFields() -> (String, [(String, ConstructorParameterDescription)])
}
