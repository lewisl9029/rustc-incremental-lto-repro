mod filler;
mod salt;

fn main() {
    println!("SALT in the source = {}", salt::SALT);
    for (name, value) in filler::checksums() {
        println!("{name} = {value}");
    }
}
