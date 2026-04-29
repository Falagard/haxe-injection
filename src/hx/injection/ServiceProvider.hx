package hx.injection;

import hx.injection.generics.GenericDefinition;
import hx.injection.Destructable;
import haxe.ds.StringMap;
#if sys
import sys.thread.Mutex;
#end

final class ServiceProvider implements Destructable implements Service {

	private var _requestedConfigs:StringMap<Any>;
	private var _requestedServices:StringMap<ServiceGroup>;
	private var _requestedInstances:StringMap<Service>;

	private var _resolvedSingletonOrder : Array<String>;
	private var _resolvedSingletons : StringMap<Service>;
	
	private var _resolvedScopeOrder : Array<String>;
	private var _resolvedScopes : StringMap<Service>;

	#if sys
	private var _mutex : Mutex;
	private var _condition : sys.thread.Condition;
	private var _lockOwner : Null<sys.thread.Thread> = null;
	private var _lockCount : Int = 0;
	private var _resolving : StringMap<sys.thread.Thread>;
	#end

	public function new(configs : StringMap<Any>, services : StringMap<ServiceGroup>, instances : StringMap<Service>) {
		_requestedConfigs = configs;
		_requestedServices = services;
		_requestedInstances = instances;

		_resolvedSingletonOrder = new Array();
		_resolvedSingletons = new StringMap();
		
		_resolvedScopeOrder = new Array();
		_resolvedScopes = new StringMap();

		#if sys
		_mutex = new Mutex();
		_condition = new sys.thread.Condition();
		_resolving = new StringMap();
		#end

		registerSelf();
	}

	private function registerSelf() {
		var name = Type.getClassName(ServiceProvider);
		_resolvedSingletonOrder.push(name);
		_resolvedSingletons.set(name, this);
	}

	/**
		Fetch a service implementation by its abstraction.
	**/
	overload public inline extern function getService<S:Service>(service:Class<S>, ?binding : Null<Class<S>>):S {
		return handleGetService(Type.getClassName(service), service, binding);
	}

	/**
		Fetch a service implementation by its abstraction.
	**/
	overload public inline extern function getService<S:Service>(service:GenericDefinition<S>, ?binding : Null<Class<S>>):S {
		return handleGetService(service.signature, service.basetype, binding);
	}

	/**
		Fetch an iterator of services by its abstraction.
	**/
	overload public inline extern function getServices<S:Service>(service:Class<S>):Iterable<S> {
		return handleGetServices(Type.getClassName(service), service);
	}

	/**
		Fetch an iterator of services by its abstraction.
	**/
	overload public inline extern function getServices<S:Service>(service:GenericDefinition<S>):Iterable<S> {
		return handleGetServices(service.signature, service.basetype);
	}

	private function handleGetService<S:Service>(name : String, service:Class<S>, ?binding : Null<Class<S>>):S {
		var serviceName = name;
		var instance = _requestedInstances.get(name);
		if(instance != null)
			return (cast instance);

		var requestedGroup = _requestedServices.get(serviceName);
		if (requestedGroup == null) {
			throw new haxe.Exception('Service of type \'${serviceName}\' not found in requested services map.');
		}

		var requestedService = null;
		switch(binding) {
			case null:
				var services = requestedGroup.getServices();
				if (services == null || services.length == 0) {
					throw new haxe.Exception('Service of type \'${serviceName}\' has no registered implementations.');
				}
				requestedService = services[0];
			default:
				requestedService = requestedGroup.getServiceAtKey(Type.getClassName(binding));
		}
		
		if (requestedService == null) {
			throw new haxe.Exception('Service implementation for \'${serviceName}\' (binding: ${binding}) not found.');
		}

		var implementation = handleServiceRequest(serviceName, requestedService);

		return (cast implementation);
	}

	private function handleGetServices<S:Service>(name : String, service:Class<S>):Iterable<S> {
		var serviceName = name;
		var requestedGroup = _requestedServices.get(serviceName);

		var services = [];
		var requestedServices = requestedGroup.getServices();
		
		if (requestedServices == null) {
			throw new haxe.Exception('Service of type \'${serviceName}\' not found.');
		}

		for(service in requestedServices) {
			services.push(handleServiceRequest(serviceName, service));
		}
		
		return cast services;
	}

	/**
		Create a new scope on the provider.
	**/
	public function newScope() : ServiceProvider {
		destroyScopes();
		_resolvedScopes = new StringMap();
		return this;
	}

	/**
		Create a new child scope on the provider.
		Singletons are shared from the parent, but scoped services are isolated.
	**/
	public function createChildScope():ServiceProvider {
		#if sys
		_mutex.acquire();
		#end
		try {
			var instances = new StringMap<Service>();
			// Share all singletons that have already been resolved
			for (name in _resolvedSingletonOrder) {
				instances.set(name, _resolvedSingletons.get(name));
			}
			// Also share any specifically requested instances
			for (name in _requestedInstances.keys()) {
				instances.set(name, _requestedInstances.get(name));
			}
			#if sys
			_mutex.release();
			#end
			return new ServiceProvider(_requestedConfigs, _requestedServices, instances);
		} catch (e:Dynamic) {
			#if sys
			_mutex.release();
			#end
			throw e;
		}
	}

	private function handleServiceRequest(name : String, serviceType:InternalServiceType):Service {
		if (serviceType == null) {
			throw new haxe.Exception('Cannot handle service request for \'${name}\' with null serviceType.');
		}

		#if sys
		var self = sys.thread.Thread.current();
		
		_mutex.acquire();
		while (true) {
			var implementation = switch (serviceType) {
				case Singleton(impl): impl;
				case Transient(impl): impl;
				case Scoped(impl): impl;
			}

			// If it's a singleton or scoped, it might already be resolved
			var existing = switch (serviceType) {
				case Singleton(impl): _resolvedSingletons.get(impl);
				case Scoped(impl): _resolvedScopes.get(impl);
				default: null;
			}
			if (existing != null) {
				_mutex.release();
				return existing;
			}

			// Check if it's currently being resolved by another thread
			var resolver = _resolving.get(implementation);
			if (resolver != null && resolver != self) {
				// Wait for it to finish (avoiding deadlocks by releasing mutex and sleeping)
				_mutex.release();
				Sys.sleep(0.01);
				_mutex.acquire();
				continue;
			}
			
			// If we are already resolving it, we have a circular dependency (forbidden for constructor injection)
			if (resolver == self) {
				_mutex.release();
				throw new haxe.Exception('Circular dependency detected during resolution of service \'${name}\' (Implementation: ${implementation}).');
			}

			// Start resolving
			_resolving.set(implementation, self);
			_mutex.release();
			
			try {
				var instance = switch (serviceType) {
					case Singleton(impl):
						var inst = buildDependencyTree(name, impl);
						_mutex.acquire();
						_resolvedSingletonOrder.insert(0, impl);
						_resolvedSingletons.set(impl, inst);
						_mutex.release();
						inst;
					case Transient(impl):
						buildDependencyTree(name, impl);
					case Scoped(impl):
						var inst = buildDependencyTree(name, impl);
						_mutex.acquire();
						_resolvedScopeOrder.insert(0, impl);
						_resolvedScopes.set(impl, inst);
						_mutex.release();
						inst;
					default: null;
				};

				_mutex.acquire();
				_resolving.remove(implementation);
				_condition.signal();
				_mutex.release();
				
				return instance;
			} catch (e:Dynamic) {
				_mutex.acquire();
				_resolving.remove(implementation);
				_condition.signal();
				_mutex.release();
				
				var errStr = Std.string(e);
				if (errStr == "Null access") {
					throw new haxe.Exception('Null access detected during resolution of service \'${name}\'. This often means a constructor failed or a dependency implementation is missing.');
				}
				throw e;
			}
		}
		#else
		// Non-sys implementation (synchronous, no mutex)
		return switch (serviceType) {
			case Singleton(implementation):
				handleSingletonService(name, implementation);
			case Transient(implementation):
				handleTransientService(name, implementation);
			case Scoped(implementation):
				handleScopedService(name, implementation);
			default:
				null;
		}
		#end
	}

	private function handleSingletonService(name : String, implementation:String):Service {

		var instance = getSingleton(implementation);
		if (instance == null) {
			instance = buildDependencyTree(name, implementation);
			_resolvedSingletonOrder.insert(0, implementation);
			_resolvedSingletons.set(implementation, instance);
		}
		return instance;
	}

	private function handleTransientService(name : String, implementation:String):Service {
		return buildDependencyTree(name, implementation);
	}

	private function handleScopedService(name : String, implementation:String):Service {
		var instance = getScoped(implementation);
		if (instance == null) {
			instance = buildDependencyTree(name, implementation);
			_resolvedScopeOrder.insert(0, implementation);
			_resolvedScopes.set(implementation, instance);
		}
		return instance;
	}

	private function buildDependencyTree(name : String, service:String):Service {
		var dependencies : Array<Dynamic> = [];
		var args = getServiceArgs(service);
		for (arg in args) {
			// trace('[DI] Resolving dependency "$arg" for service "$service" (requested by "$name")');
			var reg = ~/Iterable\((.+)\)/;
			var matched = reg.match(arg);
			switch (matched) {
				case true:
					var type = reg.matched(1);
					var dependencyArray = getRequestedService(type);
					if (dependencyArray != null) {
						var iterator = [];
						for(dependency in dependencyArray) {
							var serviceInstance = handleServiceRequest(name, dependency);
							checkLifetimeInjection(name, dependency);
							iterator.push(serviceInstance);
						}
						dependencies.push(iterator);
						continue;
					}
				case false:
					var binding = arg.split('|');
					var serviceType = null;
					switch(binding.length) {
						case 2:
							serviceType = getBoundService(binding[0], binding[1]);
						default:
							serviceType = getRequestedService(arg) != null 
							? getRequestedService(arg)[0] 
							: null;
					}
					
					if (serviceType != null) {
						try {
							var serviceInstance = handleServiceRequest(name, serviceType);
							checkLifetimeInjection(name, serviceType);
							dependencies.push(serviceInstance);
							continue;
						} catch (e:Dynamic) {
							trace('[DI] Failed to resolve "$arg" for "$service": ' + e);
							throw e;
						}
					}
				}

			var config = getRequestedConfig(arg);
			if (config != null) {
				dependencies.push(config);
				continue;
			}

			throw new haxe.Exception('Dependency ' + arg + ' for ' + service + ' is missing. Did you add it to the collection?');
		}

		var cl = Type.resolveClass(service);
		if(cl != null) 
			return Type.createInstance(cl, dependencies);
		else throw new haxe.Exception('Cannot resolve ${service} into a class.');
	}

	private function checkLifetimeInjection(name : String, next : InternalServiceType) : Void {
		var group = _requestedServices.get(name);
		for(service in group.getServices()) {
			switch(service) {
				case Singleton(implementation):
					switch(next) {
						case Transient(implementation):
							throw new haxe.Exception('Attempting to inject ${next} into Singleton(${name})');
						case Scoped(implementation):
							throw new haxe.Exception('Attempting to inject ${next} into Singleton(${name})');
						default:
					}
				default:
			}
		}
	}

	private function getServiceArgs(service:String) : Array<String> {
		var type = Type.resolveClass(service);
		if (type == null) throw new haxe.Exception('Cannot resolve ${service} into a class.');
		var instance = Type.createEmptyInstance(type);
		if (instance == null) throw new haxe.Exception('Cannot create empty instance of ${service}.');
		
		try {
			// This relies on macro-generated metadata or method
			return (instance.getConstructorArgs() : Array<String>);
		} catch (e:Dynamic) {
			return []; // Fallback if no args are defined/meta missing
		}
	}

	private function getSingleton(serviceName:String):Service {
		#if sys
		_mutex.acquire();
		#end
		var s = _resolvedSingletons.get(serviceName);
		#if sys
		_mutex.release();
		#end
		return s;
	}

	private function getScoped(serviceName:String):Service {
		#if sys
		_mutex.acquire();
		#end
		var s = _resolvedScopes.get(serviceName);
		#if sys
		_mutex.release();
		#end
		return s;
	}

	private function getRequestedConfig(config:String):Any {
		return _requestedConfigs.get(config);
	}

	private function getRequestedService(serviceName:String):Array<InternalServiceType> {
		var requested = _requestedServices.get(serviceName);
		if(requested != null) {
			return requested.getServices();
		}
		return null;
	}

	private function getBoundService(serviceName:String, key : String):InternalServiceType {
		var requested = _requestedServices.get(serviceName);
		
		return requested.getServiceAtKey(key);
	}

	public function destroy() : Void {
		#if sys
		_mutex.acquire();
		#end
		destroyScopes();
		destroySingletons();

		_requestedConfigs = null;
		_requestedServices = null;
		_resolvedSingletons = null;
		_resolvedScopes = null;
		#if sys
		_mutex.release();
		#end
	}

	private function destroySingletons() : Void {
		for(key in _resolvedSingletonOrder) {
			var singleton = _resolvedSingletons.get(key);
			if(Std.isOfType(singleton, Destructable) && singleton != this) {
				cast(singleton, Destructable).destroy();
			}
		}
	}

	private function destroyScopes() : Void {
		for(key in _resolvedScopeOrder) {
			var scope = _resolvedScopes.get(key);
			if(Std.isOfType(scope, Destructable)) {
				cast(scope, Destructable).destroy();
			}
		}
	}

	public static inline var DefaultType : String = '';

}

typedef ServiceArg = {
	var name : String;
	@:optional var params : Array<String>;
}