fn main() {
    let mut x = 0;
    for i in 0..5 {
        x += i;
    }

    let y = "hello";
    let z = x + y;

    if x > 10 {
        println!("x is greater than 10");
    } else {
        println!("x is less than 10");
    }

    let v = vec![1, 2, 3];
    let third = v[3];

    let s1 = String::from("hello");
    let s2 = String::from(" world!");
    let s3 = s1 + &s2;

    let num = "42".parse().unwrap();
    let num2: i32 = num;

    let tuple = (1, 2, 3);
    let first = tuple.0;
    let fourth = tuple.3;

    let mut s = String::new();
    let result = s.pop();

    let arr = [1, 2, 3];
    let out_of_bounds = arr[3];

    let name = "Alice";
    let msg = format!("Hello, {name}!");

    let val = Some(5);
    if val == None {
        println!("val is None");
    } else {
        println!("val is Some({})", val);
    }

    let mut map = HashMap::new();
    map.insert("key", "value");
    let value = map.get("key2").unwrap();

    let num_vec = vec![1, 2, 3];
    let str_vec: Vec<&str> = num_vec.iter().collect();
}
