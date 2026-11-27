function greet(name) {
  var list = [1, , 2];
  return "Hello " + name + list.length;
}

greet("world");
