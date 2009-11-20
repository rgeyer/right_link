class ObjectRegistry
  ObjectRegistryKey = 'object_registry'

  def self.lookup( node, name )
    init(node)
    node[ObjectRegistryKey][name]
  end

  def self.register( node, name, obj )
    init(node)
    node[ObjectRegistryKey][name] = obj
  end

  def self.unregister ( node, name, obj )
    init(node)
    node[ObjectRegistryKey].remove_key ( name )
  end

  def self.init(node)
    unless node.has_key?(ObjectRegistryKey)
      node[ObjectRegistryKey] = {}
    end
  end
end