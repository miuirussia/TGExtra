import Foundation

public final class ConstructorParameterDescription {
    public let value: Optional<Any>
    
    init(_ value: Optional<Any>) {
        self.value = value
    }
}

public final class FunctionDescription {
    public let name: String
    public let parameters: [(String, ConstructorParameterDescription)]
    
    init(name: String, parameters: [(String, ConstructorParameterDescription)]) {
        self.name = name
        self.parameters = parameters
    }
}

public protocol TypeConstructorDescription {
    func descriptionFields() -> (String, [(String, ConstructorParameterDescription)])
}
